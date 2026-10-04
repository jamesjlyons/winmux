#!/usr/bin/env python3
"""Verify persistent surface IDs using only fresh, signed headless test profiles."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid


def read_records(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def identities(records, event=None):
    result = set()
    for record in records:
        parts = record["surface_id"].split(":")
        if len(parts) != 3 or parts[0] != "browser" or record["private"] is not False:
            raise RuntimeError("Invalid or private persistent identity")
        if any(str(uuid.UUID(value)) != value for value in parts[1:]):
            raise RuntimeError("Noncanonical identity")
        if event is None or record["event"] == event:
            result.add(record["surface_id"])
    return result


def run_phase(executable, output, name, profile, extra_args):
    report = output / (name + ".jsonl")
    command = [str(executable), "--headless=new", "--user-data-dir=" + str(profile),
               "--no-first-run", "--no-default-browser-check", "--enable-logging=stderr",
               "--winmux-tab-report=" + str(report)] + extra_args
    with (output / (name + ".log")).open("x") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            # Give Chromium's normal session writer time to save. This is a
            # correctness check; elapsed time is not a performance measurement.
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError(f"{name}: test browser exited early ({process.returncode})")
                time.sleep(.1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
                    raise RuntimeError(f"{name}: test browser did not quit cleanly")
    if process.returncode != 0:
        raise RuntimeError(f"{name}: nonzero exit {process.returncode}")
    return {"name": name, "command": command, "exit_code": process.returncode,
            "records": read_records(report)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory for profiles and evidence")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    executable = app / "Contents/MacOS/Chromium"
    manifest_path = app.parent / "winmux-package-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    team = manifest.get("team_identifier", "")
    if (manifest.get("verified") is not True or not re.fullmatch(r"[A-Z0-9]{10}", team)
            or hashlib.sha256(executable.read_bytes()).hexdigest() != manifest.get("browser_executable_sha256")):
        parser.error("Expected a verified staged alpha package")
    requirement = f'anchor apple generic and identifier "com.jameslyons.winmux.browser.alpha" and certificate leaf[subject.OU] = "{team}"'
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, str(app)], check=True)
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    profile = output / "profile-a"
    result = {"scope": "actual_signed_chromium_tab_identity_persistence", "passed": False,
              "package_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
              "test_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "phases": [], "limits": ["Headless synthetic pages; no signed-in profiles or app UI inspected",
                  "Multiple tabs, renderer replacement, discard, tab duplication and crash restore remain untested",
                  "Identity persistence does not yet provide browser rows or mixed layouts"]}
    try:
        first = run_phase(executable, output, "create", profile, ["about:blank#one"])
        result["phases"].append(first)
        original = identities(first["records"])
        if len(original) != 1:
            raise RuntimeError(f"Expected one initial tab, observed {len(original)}")
        restored = run_phase(executable, output, "restore", profile, ["--restore-last-session"])
        result["phases"].append(restored)
        if identities(restored["records"], "restored") != original:
            raise RuntimeError("Restored tab identities differ from the saved session")
        second = run_phase(executable, output, "separate-profile", output / "profile-b", ["about:blank"])
        result["phases"].append(second)
        other = identities(second["records"])
        if len(other) != 1 or {x.split(":")[1] for x in original} & {x.split(":")[1] for x in other}:
            raise RuntimeError("Profile identities were not distinct")
        private = run_phase(executable, output, "private", output / "profile-private", ["--incognito", "about:blank"])
        result["phases"].append(private)
        if private["records"]:
            raise RuntimeError("Private tabs emitted persistent identity diagnostics")
        result["passed"] = True
    except (OSError, ValueError, RuntimeError) as error:
        result["error"] = str(error)
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result.get(key) for key in ("passed", "error")}), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
