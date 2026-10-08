#!/usr/bin/env python3
"""Verify spare exclusion and consumed-tab restoration in a synthetic profile."""
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

from test_browser_tab_speed import BROWSER_ID, run
from test_browser_switch_speed import require_unlocked_session
from test_browser_layout_watchdog import require_free_native_lease


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    manifest = json.loads((app.parent / "winmux-package-manifest.json").read_text())
    team = manifest.get("team_identifier", "")
    if manifest.get("verified") is not True or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("A verified signed package is required")
    executable = app / "Contents/MacOS/Chromium"
    helper = app / manifest["helper_relative_path"]
    for target, binary, identifier, key in [
        (app, executable, BROWSER_ID, "browser_executable_sha256"),
        (helper, helper, BROWSER_ID + ".workspace", "helper_sha256"),
    ]:
        if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest[key]:
            parser.error("Packaged executable changed")
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
        subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(target)], check=True)
    require_unlocked_session()
    require_free_native_lease()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # The helper retains the final consumed URL window; idle sampling gives the
    # replenished hidden spare and Chromium session writes time to settle.
    initial = run(app, manifest, output / "initial", 1, None, False, keep_last=True)
    if not initial["passed"]:
        raise RuntimeError("Initial synthetic fixture failed")
    saved = json.loads((output / "initial/helper.json").read_text())
    expected = {host["surface_id"] for host in saved["hosts"]}
    consumed = initial["samples"][-1]["surface_id"]
    if len(expected) != 2 or consumed not in expected:
        raise RuntimeError("Expected the seed and one consumed window, with no spare in inventory")

    service = BROWSER_ID + ".workspace.test." + str(uuid.uuid4())
    report = output / "restored-helper.json"
    agent = output / "restore-helper.plist"
    agent.write_bytes(plistlib.dumps({
        "Label": service, "ProgramArguments": [str(helper), service, str(report)],
        "MachServices": {service: True}, "RunAtLoad": True,
        "EnvironmentVariables": {"WINMUX_TEST_OBSERVE_ONLY": "1"},
        "StandardOutPath": str(output / "restore-helper.log"),
        "StandardErrorPath": str(output / "restore-helper.log"),
    }))
    browser = None
    result = {"passed": False, "consumed_surface": consumed, "expected_surfaces": sorted(expected),
              "package_manifest_sha256": hashlib.sha256((app.parent / "winmux-package-manifest.json").read_bytes()).hexdigest()}
    try:
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(agent)], check=True, timeout=10)
        command = [str(executable), "--user-data-dir=" + str(output / "initial/profile"),
                   "--no-first-run", "--no-default-browser-check", "--restore-last-session",
                   "--disable-background-networking", "--winmux-sidebar-preview",
                   "--winmux-test-service=" + service,
                   "--winmux-bridge-report=" + str(output / "restore-bridge.json")]
        with (output / "restore-browser.log").open("x") as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 40
            matched_at = None
            while time.monotonic() < deadline:
                if browser.poll() is not None:
                    raise RuntimeError("Restore browser exited")
                if report.exists():
                    state = json.loads(report.read_text())
                    actual = {host["surface_id"] for host in state["hosts"]}
                    matched_at = (matched_at or time.monotonic()) if actual == expected else None
                    # Observe after warming has had time to replenish too.
                    if matched_at and time.monotonic() - matched_at >= 1:
                        result.update(passed=True, restored_surfaces=sorted(actual),
                                      spare_excluded=True, consumed_window_restored=True)
                        break
                time.sleep(.025)
            else:
                raise TimeoutError("Session did not restore exactly the two user windows")
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        if browser and browser.poll() is None:
            browser.terminate()
            try:
                browser.wait(timeout=10)
            except subprocess.TimeoutExpired:
                browser.kill(); browser.wait(timeout=10)
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{service}"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
