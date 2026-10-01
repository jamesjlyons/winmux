#!/usr/bin/env python3
"""Exercise signed Chromium reconnection without restarting a shared helper.

Creates a new headless profile and stops only the process it launches. The opt-in
diagnostic invalidates that client's connection once. Both negotiation timeout
windows must pass after reauthentication. Never inspects existing browser UI.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

from measure_helper import Sampler


def identity(sample):
    return sample["process_start_ticks"], sample["executable_uuid"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--helper-pid", type=int, required=True)
    parser.add_argument("--helper-executable", type=Path, required=True)
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
    if args.profile.exists() or args.output.exists():
        parser.error("Profile and output must both be new paths")
    helper = Sampler(args.helper_pid, args.helper_executable)
    initial_helper = identity(helper.read())
    args.profile.mkdir(parents=True, exist_ok=False)
    args.output.mkdir(parents=True, exist_ok=False)
    report_path = args.output.resolve() / "bridge.json"
    command = [str(executable), "--headless=new", "--user-data-dir=" + str(args.profile.resolve()),
               "--no-first-run", "--no-default-browser-check", "--enable-logging=stderr",
               "--winmux-bridge-report=" + str(report_path), "--winmux-bridge-test-disconnect-once", "about:blank"]
    result = {"scope": "actual_signed_headless_chromium_connection_recovery", "passed": False,
              "args": command, "package_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
              "test_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "observations": [], "limits": ["Only this test client's XPC connection is invalidated; no helper crash is injected",
                                           "No UI, presentation, native window management or performance qualification",
                                           "Existing profiles and signed-in extension UI are not inspected"]}
    with (args.output / "browser.log").open("x") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        result["browser_pid"] = process.pid
        start, recovered_at, previous = time.monotonic(), None, None
        try:
            while time.monotonic() - start < 60:
                if process.poll() is not None:
                    raise RuntimeError("Test browser exited before observation completed")
                if report_path.exists():
                    current = json.loads(report_path.read_text())
                    if current != previous:
                        result["observations"].append({"elapsed_seconds": time.monotonic() - start, "report": current})
                        previous = current
                        print(json.dumps(result["observations"][-1]), flush=True)
                    if current.get("state") == "authenticated" and current.get("authenticated_connections") == 2:
                        if recovered_at is None:
                            recovered_at = time.monotonic()
                        if time.monotonic() - recovered_at >= 17:
                            break
                    elif recovered_at is not None:
                        raise RuntimeError("Recovered connection did not remain stable")
                time.sleep(.1)
            result["helper_identity_unchanged"] = identity(helper.read()) == initial_helper
            result["seconds_after_reauthentication"] = None if recovered_at is None else time.monotonic() - recovered_at
            states = [(x["report"]["state"], x["report"]["connection_generation"],
                       x["report"]["authenticated_connections"]) for x in result["observations"]]
            result["passed"] = (states == [("authenticated", 1, 1), ("disconnected", 1, 1), ("authenticated", 2, 2)]
                                and result["helper_identity_unchanged"] and recovered_at is not None
                                and result["seconds_after_reauthentication"] >= 17)
        except (OSError, ValueError, RuntimeError) as error:
            result["error"] = str(error)
        finally:
            result["elapsed_seconds"] = time.monotonic() - start
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                result["passed"] = False
                result["error"] = "Isolated test browser did not quit normally"
                process.kill()
                process.wait(timeout=10)
            result["test_process_exit_code"] = process.returncode
            (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result.get(k) for k in ("passed", "helper_identity_unchanged", "seconds_after_reauthentication", "error")}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
