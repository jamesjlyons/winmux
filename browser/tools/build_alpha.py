#!/usr/bin/env python3
"""Preserve the control, then incrementally build owned Chromium integration."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

import chromium

ROOT = chromium.ROOT
CONFIG = ROOT / "browser/chromium"
OWNED_PREFIXES = ("chrome/browser/winmux/", "chrome/renderer/winmux/",
                  "components/winmux/", "services/network/winmux/")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def owned_patch_state(source, patch):
    actual = subprocess.check_output([
        "git", "diff", "--binary", "--full-index", "--no-ext-diff", "--no-color", "HEAD"
    ], cwd=source)
    if actual not in (b"", patch):
        raise RuntimeError("Unowned Chromium changes found; refusing to overwrite")
    return bool(actual)


def integration_patches():
    return sorted((CONFIG / "patches").glob("*.patch"))


def owned_patch_prefix(source, patches):
    """Accept only the clean pin or an exact prefix of the owned patch series."""
    command = ["git", "diff", "--binary", "--full-index", "--no-ext-diff", "--no-color", "HEAD"]
    actual = subprocess.check_output(command, cwd=source)
    matched = 0 if not actual else None
    with tempfile.TemporaryDirectory(prefix="winmux-patch-index-") as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"))
        chromium.run("git", "read-tree", "HEAD", cwd=source, env=env)
        for count, patch in enumerate(patches, 1):
            chromium.run("git", "apply", "--cached", str(patch), cwd=source, env=env)
            expected = subprocess.check_output(command + ["--cached"], cwd=source, env=env)
            if actual == expected:
                matched = count
    if matched is None:
        raise RuntimeError("Unowned Chromium changes found; refusing to overwrite")
    return matched


def acquire_engine_lock(engine, exclusive=True):
    lock = (engine / "winmux-alpha-build.lock").open("a")
    try:
        mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        fcntl.flock(lock, mode | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise RuntimeError("Another alpha build/package operation owns this engine; refusing a concurrent build") from None
    return lock


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    engine = args.root.expanduser().resolve()
    with acquire_engine_lock(engine):
        build(args, engine)


def build(args, engine):
    report = chromium.preflight(engine, "build")
    print(json.dumps(report, indent=2), flush=True)
    if report["blockers"]:
        raise SystemExit(2)
    source = engine / "chromium/src"
    pin = chromium.PINS["chromium"]["revision"]
    if chromium.output("git", "rev-parse", "HEAD", cwd=source) != pin:
        raise RuntimeError("Unexpected Chromium revision; refusing to patch")
    if chromium.output("git", "rev-parse", "HEAD", cwd=engine / "depot_tools") != chromium.PINS["depot_tools"]["revision"]:
        raise RuntimeError("Unexpected depot_tools revision")
    # Siso records output paths in its dependency/cache state. Changing the
    # output directory invalidates those records, even with APFS-cloned files.
    # Archive the completed baseline and keep the working output path stable.
    output = source / "out/WinMuxControl"
    control = source / "out/WinMuxControlBaseline"
    owner = {"source": str(source), "chromium_revision": pin}
    if control.exists():
        marker = control / "winmux-control-owner.json"
        if not marker.exists() or json.loads(marker.read_text()) != owner:
            raise RuntimeError("Refusing to reuse an unrelated control archive")
    baseline_source = control if control.exists() else output
    baseline = json.loads((baseline_source / "winmux-build-manifest.json").read_text())
    build_args = (CONFIG / "args.gn").read_bytes()
    if baseline["configuration"] != "browser-only-control" or baseline["args_sha256"] != digest(build_args):
        raise RuntimeError("A completed control with matching configuration is required")
    patches = integration_patches()
    patch_prefix = owned_patch_prefix(source, patches)
    state_path = engine / "alpha-build-state.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    old_hashes = state.get("overlay_sha256", {})
    previous_library_hash = state.get("blocking", {}).get("library_sha256")
    overlay = {
        str(p.relative_to(CONFIG / "overlay")): p.read_bytes()
        for p in (CONFIG / "overlay").rglob("*") if p.is_file()
    }
    overlay["chrome/browser/winmux/WMBridgeProtocol.h"] = (
        ROOT / "browser/native/Sources/BridgeProtocol/include/WMBridgeProtocol.h").read_bytes()
    overlay["components/winmux/blocking/winmux_blocking.h"] = (
        ROOT / "browser/blocking/include/winmux_blocking.h").read_bytes()
    existing = {str(p.relative_to(source)) for prefix in OWNED_PREFIXES
                for p in (source / prefix).rglob("*") if p.is_file()}
    existing.discard("components/winmux/blocking/prebuilt/libwinmux_blocking.dylib")
    if existing - overlay.keys():
        raise RuntimeError("Unknown files in the integration directory")
    for name, data in overlay.items():
        target = source / name
        if target.exists() and target.read_bytes() != data and digest(target.read_bytes()) != old_hashes.get(name):
            raise RuntimeError(f"Unowned integration edit: {name}")
    marker = output / "winmux-alpha-owner.json"
    if marker.exists() and json.loads(marker.read_text()) != owner:
        raise RuntimeError("Refusing to reuse an unrelated alpha build cache")
    if not marker.exists():
        current = json.loads((output / "winmux-build-manifest.json").read_text())
        if current != baseline:
            raise RuntimeError("Working cache does not match the archived baseline")
    if not control.exists():
        chromium.run("cp", "-cpR", str(output), str(control))
        (control / "winmux-control-owner.json").write_text(json.dumps(owner, indent=2) + "\n")
    marker.write_text(json.dumps(owner, indent=2) + "\n")
    for patch in patches[patch_prefix:]:
        chromium.run("git", "apply", "--check", str(patch), cwd=source)
        chromium.run("git", "apply", str(patch), cwd=source)
    for name, data in overlay.items():
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != data:
            target.write_bytes(data)
    state = {**owner, "configuration": "alpha-milestone-0", "build_succeeded": False,
             "patches_sha256": {p.name: digest(p.read_bytes()) for p in patches}, "args_sha256": digest(build_args),
             "overlay_sha256": {name: digest(data) for name, data in overlay.items()},
             "build_jobs": args.jobs, "build_directory": str(output),
             "control_directory": str(control)}
    state_path.write_text(json.dumps(state, indent=2) + "\n")
    manifest_path = output / "winmux-build-manifest.json"
    manifest_path.write_text(json.dumps(state, indent=2) + "\n")
    import prepare_blocking
    state["blocking"] = prepare_blocking.prepare(output, args.jobs, previous_library_hash)
    state_path.write_text(json.dumps(state, indent=2) + "\n")
    manifest_path.write_text(json.dumps(state, indent=2) + "\n")
    if (output / "args.gn").read_bytes() != build_args:
        (output / "args.gn").write_bytes(build_args)
    env = dict(os.environ, DEPOT_TOOLS_UPDATE="0", DEPOT_TOOLS_METRICS="0")
    env["PATH"] += os.pathsep + str(engine / "depot_tools")
    chromium.run(str(engine / "depot_tools/gn"), "gen", str(output), cwd=source, env=env)
    chromium.run(str(engine / "depot_tools/autoninja"), "-C", str(output), "-j", str(args.jobs),
                 "chrome/browser/winmux:workspace_bridge", "components/winmux/blocking:engine",
                 "chrome/renderer/winmux:cosmetics_agent",
                 "obj/services/network/network_service/url_filter.o", cwd=source, env=env)
    chromium.run(str(engine / "depot_tools/autoninja"), "-C", str(output), "-j", str(args.jobs),
                 "chrome", "chrome/installer/mac", cwd=source, env=env)
    state.update(build_succeeded=True, native_revision=chromium.output("git", "rev-parse", "HEAD", cwd=ROOT),
                 native_dirty=bool(chromium.output("git", "status", "--porcelain", cwd=ROOT)),
                 control_manifest=baseline, qualification="not_run")
    state_path.write_text(json.dumps(state, indent=2) + "\n")
    manifest_path.write_text(json.dumps(state, indent=2) + "\n")


if __name__ == "__main__":
    main()
