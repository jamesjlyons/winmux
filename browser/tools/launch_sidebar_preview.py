#!/usr/bin/env python3
"""Launch the signed real sidebar against fresh synthetic tabs, without a WM.

The session ends when its output/stop file is created (or after 15 minutes).
Only this launcher's browser and uniquely named test service are stopped. The
installed alpha, enrolled helper, user profiles and native manager are untouched.
UI interactions must be performed through the supported Computer Use tool.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-process", type=int,
                        help="Explicitly activate isolated native management of ONLY this launch-bound fixture PID")
    parser.add_argument("--resume-from", type=Path, help="Reuse only a previous isolated test profile/state to verify restart")
    parser.add_argument("--allow-clean-exit", action="store_true", help="Treat a user-driven normal test-browser quit as completion")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    manifest = json.loads((app.parent / "winmux-package-manifest.json").read_text())
    team = manifest.get("team_identifier", "")
    if not manifest.get("verified") or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("Requires a verified Personal Team alpha package")
    executable = app / "Contents/MacOS/Chromium"
    helper = app / manifest["helper_relative_path"]
    helper_app = helper.parents[2]
    browser_id = "com.jameslyons.winmux.browser.alpha"
    for path, binary, identifier, key in [(app, executable, browser_id, "browser_executable_sha256"),
        (helper, helper, browser_id + ".workspace", "helper_sha256")]:
        if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest.get(key):
            parser.error("Packaged executable changed")
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, str(path)], check=True)
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    resume = args.resume_from.resolve(strict=True) if args.resume_from else None
    if resume:
        previous = json.loads((resume / "result.json").read_text())
        if (previous.get("scope") != "isolated_native_browser_sidebar" or args.native_process is None or
            not previous.get("test_service_removed") or not (resume / "profile").is_dir() or
            (resume / "native-state/winmux-browser-state-v1").read_text() != "isolated-browser-workspace\n"):
            parser.error("Resume requires a completed isolated native test's profile and marked state")
    state_root = resume or output
    service = browser_id + ".workspace.test." + str(uuid.uuid4())
    helper_arguments = [str(helper), service, str(output / "helper.json"), "--sidebar-preview"]
    if args.native_process is not None:
        if args.native_process <= 0:
            parser.error("Native fixture PID must be positive")
        helper_arguments = [str(helper), service, str(output / "helper.json"), "--manage-native",
                            str(state_root / "native-state"), "--native-process", str(args.native_process)]
    plist = output / "helper.plist"
    plist.write_bytes(plistlib.dumps({"Label": service, "ProgramArguments": helper_arguments, "MachServices": {service: True},
        "RunAtLoad": True, "ProcessType": "Interactive",
        "StandardOutPath": str(output / "helper.log"), "StandardErrorPath": str(output / "helper.log")}))
    for name, title in [("one", "WinMux Sidebar One"), ("two", "WinMux Sidebar Two")]:
        (output / (name + ".html")).write_text(f'<!doctype html><title>{title}</title><h1>{title}</h1><input aria-label="Test input">')
    command = [str(executable), "--user-data-dir=" + str(state_root / "profile"), "--no-first-run",
        "--no-default-browser-check", "--enable-logging=stderr", "--winmux-sidebar-preview",
        "--winmux-test-service=" + service, "--winmux-bridge-report=" + str(output / "bridge.json")]
    command += ["--restore-last-session"] if resume else [(output / "one.html").as_uri(), (output / "two.html").as_uri()]
    result = {"scope": "isolated_live_sidebar", "service": service, "app": str(app), "completed": False,
              "limits": ["No native manager activation; mixed layouts and native input readiness not qualified"]}
    if args.native_process is not None:
        result.update(scope="isolated_native_browser_sidebar", native_fixture_pid=args.native_process,
                      limits=["Native management restricted to the explicit fixture process; mixed layouts not qualified"])
    if resume:
        result["resumed_from"] = str(resume)
    process, bootstrapped = None, False
    with (output / "browser.log").open("x") as log:
        try:
            # A launchd-started accessory app is not automatically indexed by
            # Launch Services. Register this exact staging app for Computer Use.
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                            "-f", str(helper_app)], check=True)
            subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True)
            bootstrapped = True
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            result["browser_pid"] = process.pid
            (output / "session.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result), flush=True)
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline and not (output / "stop").exists():
                if process.poll() is not None:
                    if args.allow_clean_exit and process.returncode == 0:
                        result["completed"] = True
                        break
                    raise RuntimeError(f"Test browser exited: {process.returncode}")
                time.sleep(.25)
            result["completed"] = result["completed"] or (output / "stop").exists()
        finally:
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
                result["browser_exit_code"] = process.returncode
            if bootstrapped:
                cleanup = subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{service}"], capture_output=True)
                result["test_service_removed"] = cleanup.returncode == 0
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
