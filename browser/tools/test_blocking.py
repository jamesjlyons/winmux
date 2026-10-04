#!/usr/bin/env python3
"""Verify bundled snapshots, run Rust tests, and measure the C++/Rust boundary."""
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
BLOCKING = ROOT / "browser/blocking"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    scratch = ROOT / ".local/browser"
    scratch.mkdir(parents=True, exist_ok=True)
    pins = json.loads((ROOT / "browser/chromium/pins.json").read_text())
    rust = subprocess.check_output(["rustc", "--version"], text=True).strip()
    if rust.split()[1] != pins["rust_version"]:
        raise SystemExit("Rust version differs from the recorded qualification toolchain")
    manifest = json.loads((BLOCKING / "resources/manifest.json").read_text())
    lists = []
    for entry in manifest["lists"]:
        content = gzip.decompress((BLOCKING / "resources" / entry["file"]).read_bytes())
        if hashlib.sha256(content).hexdigest() != entry["sha256"]:
            raise SystemExit("Bundled filter snapshot checksum mismatch")
        lists.append(content)
    rules = scratch / "bundled-rules.txt"
    rules.write_bytes(b"\n".join(lists))
    run("cargo", "test", "--locked", "--offline", "--release", "--manifest-path", str(BLOCKING / "Cargo.toml"))
    run("cargo", "build", "--locked", "--offline", "--release", "--manifest-path", str(BLOCKING / "Cargo.toml"))
    probe = scratch / "blocking-probe"
    run("xcrun", "clang++", "-std=c++20", "-O2", "-I", str(BLOCKING / "include"),
        str(BLOCKING / "tests/native_probe.cc"), str(BLOCKING / "target/release/libwinmux_blocking.a"),
        "-framework", "Security", "-framework", "CoreFoundation", "-liconv", "-o", str(probe))
    result = subprocess.check_output([str(probe), str(rules)], text=True)
    report = json.loads(result)
    report["lists"] = manifest["lists"]
    report["rust_version"] = rust
    report["os"] = subprocess.check_output(["sw_vers"], text=True).strip()
    report["recorded_utc"] = datetime.now(timezone.utc).isoformat()
    report["qualification_conditions"] = "Development machine during implementation; not controlled browser qualification"
    report["source_sha256"] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [BLOCKING / "src/lib.rs", BLOCKING / "tests/native_probe.cc", BLOCKING / "Cargo.lock"]}
    (scratch / "blocking-proof.json").write_text(json.dumps(report, indent=2) + "\n")
    print(result)


if __name__ == "__main__":
    main()
