#!/usr/bin/env python3
"""Pinned upstream checkout/build with resource gates; no implicit data cleanup."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "browser/chromium"
PINS = json.loads((CONFIG / "pins.json").read_text())
GIB = 1024 ** 3


def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


def output(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def filesystem(path):
    # Resolve the actual device, including APFS volumes mounted below /Volumes.
    device = output("/bin/df", "-P", str(path)).splitlines()[-1].split()[0]
    raw = subprocess.check_output(["/usr/sbin/diskutil", "info", "-plist", device], stderr=subprocess.PIPE)
    info = plistlib.loads(raw)
    return info.get("FilesystemType", "unknown")


def preflight(path, stage):
    existing = path
    while not existing.exists():
        existing = existing.parent
    free = shutil.disk_usage(existing).free
    required = PINS["initial_checkout_free_gib" if stage == "fetch" else "minimum_build_free_gib"]
    report = {
        "build_root": str(path), "stage": stage, "free_gib": round(free / GIB, 2),
        "required_free_gib": required, "machine": platform.machine(),
        "os": platform.mac_ver()[0], "chromium": PINS["chromium"], "blockers": [],
    }
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        report["blockers"].append("Initial qualification requires Apple silicon macOS.")
    if " " in str(path):
        report["blockers"].append("Chromium build root must have no spaces.")
    if free < required * GIB:
        report["blockers"].append(f"Need at least {required} GiB free before {stage}; no files were removed.")
    try:
        report["filesystem"] = filesystem(existing)
        if report["filesystem"] != "apfs":
            report["blockers"].append("Chromium requires an APFS build volume.")
    except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
        report["blockers"].append("Could not inspect build filesystem; rerun preflight with disk metadata access.")
    return report


def ensure_clone(path, pin):
    if path.exists():
        if not (path / ".git").exists():
            raise RuntimeError(f"Refusing to reuse non-repository {path}")
        if output("git", "rev-parse", "HEAD", cwd=path) != pin["revision"]:
            raise RuntimeError(f"Unexpected revision in {path}; refusing to reset it.")
        if output("git", "status", "--porcelain", cwd=path):
            raise RuntimeError(f"Dirty checkout {path}; refusing to overwrite it.")
        return
    path.mkdir(parents=True)
    run("git", "init", str(path))
    run("git", "remote", "add", "origin", pin["repository"], cwd=path)
    run("git", "fetch", "--depth=1", "origin", pin["revision"], cwd=path)
    run("git", "checkout", "--detach", "FETCH_HEAD", cwd=path)


def fetch(path, env):
    ensure_clone(path / "depot_tools", PINS["depot_tools"])
    checkout = path / "chromium"
    checkout.mkdir(exist_ok=True)
    config = checkout / ".gclient"
    spec = "solutions = " + repr([{
        "name": "src", "url": PINS["chromium"]["repository"], "managed": False,
        "custom_deps": {}, "custom_vars": {},
    }]) + "\ntarget_os = ['mac']\n"
    if config.exists() and config.read_text() != spec:
        raise RuntimeError("Existing .gclient differs; refusing to replace it.")
    config.write_text(spec)
    ensure_clone(checkout / "src", PINS["chromium"])
    run(str(path / "depot_tools/gclient"), "sync", "--no-history", "--revision",
        "src@" + PINS["chromium"]["revision"], cwd=checkout, env=env)


def build(path, env):
    source = path / "chromium/src"
    if output("git", "rev-parse", "HEAD", cwd=source) != PINS["chromium"]["revision"]:
        raise RuntimeError("Chromium revision differs from pins.json")
    if output("git", "status", "--porcelain", "--untracked-files=no", cwd=source):
        raise RuntimeError("Baseline requires an unmodified upstream checkout")
    if output("git", "rev-parse", "HEAD", cwd=path / "depot_tools") != PINS["depot_tools"]["revision"]:
        raise RuntimeError("depot_tools revision differs from pins.json")
    build_dir = source / "out/WinMuxControl"
    build_dir.mkdir(parents=True, exist_ok=True)
    args = (CONFIG / "args.gn").read_bytes()
    (build_dir / "args.gn").write_bytes(args)
    run(str(path / "depot_tools/gn"), "gen", str(build_dir), cwd=source, env=env)
    run(str(path / "depot_tools/autoninja"), "-C", str(build_dir), "chrome", cwd=source, env=env)
    manifest = {
        "pins": PINS, "configuration": "browser-only-control", "qualification": "not_run",
        "args_sha256": hashlib.sha256(args).hexdigest(),
        "native_revision": output("git", "rev-parse", "HEAD", cwd=ROOT),
        "native_dirty": bool(output("git", "status", "--porcelain", cwd=ROOT)),
        "os": output("sw_vers"), "xcode": output("xcodebuild", "-version"),
        "rust": output("rustc", "--version"), "swift": output("swift", "--version"),
        "cargo_lock_sha256": hashlib.sha256((ROOT / "browser/blocking/Cargo.lock").read_bytes()).hexdigest(),
    }
    (build_dir / "winmux-build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["preflight", "fetch", "build-control"])
    parser.add_argument("--root", required=True, type=Path)
    options = parser.parse_args()
    path = options.root.expanduser().resolve()
    stage = "build" if options.command == "build-control" else "fetch"
    report = preflight(path, stage)
    print(json.dumps(report, indent=2), flush=True)
    if report["blockers"]:
        return 2
    if options.command == "preflight":
        return 0
    env = dict(os.environ, DEPOT_TOOLS_UPDATE="0", DEPOT_TOOLS_METRICS="0")
    env["PATH"] += os.pathsep + str(path / "depot_tools")
    if options.command == "fetch":
        fetch(path, env)
    else:
        build(path, env)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
