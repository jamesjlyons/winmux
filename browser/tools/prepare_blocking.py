"""Compile the pinned blocker with embedded, checksum-verified filter snapshots."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import chromium


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(output, jobs, previous_library_hash=None):
    root = chromium.ROOT
    blocking = root / "browser/blocking"
    resources = blocking / "resources"
    manifest = json.loads((resources / "manifest.json").read_text())
    lists = []
    for entry in manifest["lists"]:
        data = gzip.decompress((resources / entry["file"]).read_bytes())
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise RuntimeError("Bundled filter snapshot checksum mismatch")
        lists.append(data)
    rules = root / ".local/browser/chromium-bundled-rules.txt"
    content = b"\n".join(lists)
    if not rules.exists() or rules.read_bytes() != content:
        rules.write_bytes(content)
    env = dict(os.environ)
    local_cargo = root / ".local/browser/toolchains/cargo"
    if local_cargo.is_dir():
        env.update(CARGO_HOME=str(local_cargo),
                   RUSTUP_HOME=str(root / ".local/browser/toolchains/rustup"),
                   PATH=str(local_cargo / "bin") + os.pathsep + env["PATH"])
    rust = subprocess.check_output(["rustc", "--version"], env=env, text=True).strip()
    if rust.split()[1] != chromium.PINS["rust_version"]:
        raise RuntimeError("Rust version differs from the pinned qualification toolchain")
    env.update(WINMUX_BUNDLED_RULES_PATH=str(rules), CARGO_BUILD_JOBS=str(jobs))
    chromium.run("cargo", "build", "--locked", "--offline", "--release",
                 "--features", "chromium-bundled", "--manifest-path", str(blocking / "Cargo.toml"), env=env)
    library = blocking / "target/release/libwinmux_blocking.dylib"
    destination = output.parents[1] / "components/winmux/blocking/prebuilt" / library.name
    # Isolate the Rust unwind runtime in its own dylib. The framework resolves
    # this from its own Libraries directory in both browser and helper processes.
    staged = root / ".local/browser/libwinmux_blocking.dylib"
    shutil.copy2(library, staged)
    chromium.run("install_name_tool", "-id", "@loader_path/Libraries/libwinmux_blocking.dylib", str(staged))
    chromium.run("codesign", "--force", "--sign", "-", str(staged))
    if destination.exists() and sha256(destination) not in (sha256(staged), previous_library_hash):
        raise RuntimeError("Unowned blocker library edit; refusing to overwrite")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() or sha256(destination) != sha256(staged):
        shutil.copy2(staged, destination)
    return {"rust_version": rust, "lists": manifest["lists"],
            "embedded_rules_sha256": sha256(rules), "library_sha256": sha256(destination),
            "source_sha256": {str(p.relative_to(root)): sha256(p) for p in
                [blocking / "Cargo.toml", blocking / "Cargo.lock", blocking / "src/lib.rs",
                 blocking / "include/winmux_blocking.h", resources / "manifest.json"]}}
