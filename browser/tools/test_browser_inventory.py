#!/usr/bin/env python3
"""Test signed browser inventory/actions through an isolated launchd service.

The existing SMAppService enrollment and installed browser remain untouched.
Only fresh headless test tabs are navigated, arranged, focused, and closed. All artifacts stay in a new
directory; the test service is booted out and its own browser stopped on exit.
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

from measure_helper import Sampler


def identity(sample):
    return sample["process_start_ticks"], sample["executable_uuid"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--existing-helper-pid", type=int, required=True)
    parser.add_argument("--existing-helper-executable", type=Path, required=True)
    parser.add_argument("--private", action="store_true", help="Verify private tabs never enter helper inventory")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    executable = app / "Contents/MacOS/Chromium"
    manifest_path = app.parent / "winmux-package-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    helper = app / manifest.get("helper_relative_path", "Contents/Helpers/WinMuxWorkspaceHelper")
    team = manifest.get("team_identifier", "")
    if manifest.get("verified") is not True or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("A verified staged alpha package is required")
    browser_id = "com.jameslyons.winmux.browser.alpha"
    for path, identifier, hash_key in [(app, browser_id, "browser_executable_sha256"),
                                       (helper, browser_id + ".workspace", "helper_sha256")]:
        binary = executable if path == app else helper
        if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest.get(hash_key):
            parser.error("Packaged executable changed after signing")
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, str(path)], check=True)
    existing = Sampler(args.existing_helper_pid, args.existing_helper_executable)
    before = identity(existing.read())
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    service = browser_id + ".workspace.test." + str(uuid.uuid4())
    helper_report = output / "helper.json"
    bridge_report = output / "bridge.json"
    plist = output / "test-helper.plist"
    plist.write_bytes(plistlib.dumps({"Label": service, "ProgramArguments": [str(helper), service, str(helper_report)],
        "MachServices": {service: True}, "RunAtLoad": True,
        "StandardOutPath": str(output / "helper.log"), "StandardErrorPath": str(output / "helper.log")}))
    command = [str(executable), "--headless=new", "--user-data-dir=" + str(output / "profile"),
               "--no-first-run", "--no-default-browser-check", "--enable-logging=stderr",
               "--winmux-bridge-report=" + str(bridge_report), "--winmux-test-service=" + service,
               "--winmux-bridge-test-disconnect-once"]
    command += ["--incognito"] if args.private else ["--winmux-test-inventory-actions"]
    command += ["about:blank"]
    expected = {"focus": "issued", "stale_focus": "stale_focus", "close": "issued", "repeated_close": "issued",
                "operation_conflict": "operation_conflict", "foreign_epoch": "stale_epoch",
                "native_focus_fence": "issued", "repeated_fence": "issued",
                "layout_split": "issued", "layout_repeat": "issued", "layout_stale": "stale_layout",
                "layout_split_host_count": "2", "layout_identity_retained": "yes", "layout_frames_match": "yes",
                "layout_independent_native_windows": "yes", "layout_managed": "yes",
                "layout_conflict": "operation_conflict", "layout_group": "issued",
                "layout_grouped_host_count": "2", "layout_grouped_window_ids_retained": "yes",
                "layout_selected_page_only": "yes", "layout_hide": "issued", "layout_hidden": "yes",
                "layout_minimum_rejected": "unsupported", "layout_minimum_no_mutation": "yes",
                "layout_legacy_controls": "issued", "layout_legacy_controls_restored": "yes",
                "layout_readopt": "issued", "layout_readopted_window_ids": "yes",
                "navigation_legacy_rejected": "unsupported", "navigate_first": "issued", "navigate_second": "issued",
                "navigate_repeat": "issued", "navigate_payload_conflict": "operation_conflict",
                "navigate_stale_revision": "stale_revision", "navigate_invalid_url": "invalid_request",
                "back": "issued", "back_state": "yes", "forward": "issued", "forward_state": "yes",
                "reload": "issued", "stop": "issued", "navigation_keeps_native_windows": "yes",
                "new_tab": "issued", "new_tab_independent_native_window": "yes", "new_tab_close": "issued"}
    expected_count = 0 if args.private else 1
    if args.private:
        expected = {}
    result = {"scope": "actual_signed_browser_protocol4_page_windows_navigation", "passed": False,
        "package_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "test_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "command": command, "service": service, "private_inventory_test": args.private, "observations": [],
        "limits": ["Headless synthetic tabs; focus acknowledgement is not UI/input-ready confirmation",
                   "No native window manager or shared sidebar is launched",
                   "Existing browser profiles, helper enrollment and signed-in UI are preserved"]}
    process, bootstrapped = None, False
    with (output / "browser.log").open("x") as log:
        try:
            subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True)
            bootstrapped = True
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            start, previous, recovered_at = time.monotonic(), None, None
            while time.monotonic() - start < 45:
                if process.poll() is not None:
                    raise RuntimeError(f"Test browser exited early: {process.returncode}")
                if helper_report.exists() and bridge_report.exists():
                    report = json.loads(helper_report.read_text())
                    bridge = json.loads(bridge_report.read_text())
                    if report != previous:
                        result["observations"].append({"elapsed_seconds": time.monotonic() - start, "helper": report})
                        previous = report
                    if (bridge.get("authenticated_connections") == 1 and report.get("outcomes") == expected
                            and report.get("tab_count") == expected_count):
                        result["actions"] = report
                    if ("actions" in result and bridge.get("state") == "authenticated" and bridge.get("protocol_version") == 4
                            and bridge.get("authenticated_connections") == 2 and report.get("tab_count") == expected_count
                            and report.get("full_messages") == 1 and report.get("outcomes") == {}):
                        if recovered_at is None:
                            recovered_at = time.monotonic()
                        if time.monotonic() - recovered_at >= 17:
                            result.update(bridge=bridge, helper=report, seconds_after_recovery=time.monotonic()-recovered_at)
                            result["passed"] = (result["actions"].get("full_messages") == 1
                                and result["actions"].get("delta_messages", 0) >= (0 if args.private else 2))
                            break
                    elif recovered_at is not None:
                        raise RuntimeError("Recovered inventory did not remain stable")
                time.sleep(.1)
            if not result["passed"]:
                result["error"] = "Expected protocol4 page-window/navigation outcomes were not observed"
                observed = previous.get("outcomes", {}) if previous else {}
                result["missing_or_incorrect_outcomes"] = {
                    key: {"expected": value, "actual": observed.get(key)}
                    for key, value in expected.items() if observed.get(key) != value
                }
        except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
            result["error"] = str(error)
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
                if process.returncode != 0:
                    result["passed"] = False
            if bootstrapped:
                cleanup = subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{service}"], capture_output=True, text=True)
                result["test_service_removed"] = cleanup.returncode == 0
                result["passed"] = result["passed"] and cleanup.returncode == 0
            try:
                result["existing_helper_unchanged"] = identity(existing.read()) == before
            except OSError:
                result["existing_helper_unchanged"] = False
            result["passed"] = result["passed"] and result["existing_helper_unchanged"]
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result.get(key) for key in ("passed", "helper", "existing_helper_unchanged", "test_service_removed", "error")}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
