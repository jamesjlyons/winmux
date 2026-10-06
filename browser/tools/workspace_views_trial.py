#!/usr/bin/env python3
"""Prepare/start/stop a fixture-scoped workspace-views trial.

The trial has its own profile, state, native fixture, and launchd service. Start
refuses while another native manager owns windows; it never stops that manager.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import signal
import subprocess
import sys
import time
import uuid

from measure_helper import Sampler

ROOT = Path(__file__).resolve().parents[2]
MARKER = "winmux-workspace-views-trial-v1"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def identity(pid, executable):
    sample = Sampler(pid, Path(executable)).read()
    return {"pid": pid, "executable": str(Path(executable).resolve()),
            "start": sample["process_start_ticks"], "uuid": sample["executable_uuid"]}


def is_same_process(record):
    try:
        return identity(record["pid"], record["executable"]) == record
    except (OSError, RuntimeError):
        return False


def prepare(directory, app):
    app = app.resolve(strict=True)
    manifest = json.loads((app.parent / "winmux-package-manifest.json").read_text())
    if not manifest.get("verified"):
        raise RuntimeError("A verified staged package is required")
    helper = app / manifest["helper_relative_path"]
    if hashlib.sha256(helper.read_bytes()).hexdigest() != manifest["helper_sha256"]:
        raise RuntimeError("Staged helper changed after packaging")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    directory.mkdir(parents=True, exist_ok=False)
    state = directory / "native-state"
    state.mkdir()
    (state / "winmux-browser-state-v1").write_text("isolated-browser-workspace\n")
    (state / "winmux.toml").write_text("""config-version = 2
start-at-login = false
auto-reload-config = true
persistent-workspaces = []
workspace-interaction-mode = 'views'
shortcuts-preset = 'none'
automatically-unhide-macos-hidden-apps = false
[workspace-sidebar]
enabled = true
always-expanded = true
chrome-style = 'solid'
solid-chrome-color = 'system'
[mode.main.binding]
alt-j = 'focus tab-next'
alt-k = 'focus tab-prev'
alt-space = 'layout horizontal vertical'
""")
    fixture = directory / "WinMux Views Fixture.app"
    binary = fixture / "Contents/MacOS/Fixture"
    binary.parent.mkdir(parents=True)
    run("xcrun", "swiftc", str(ROOT / "browser/tools/native_window_fixture.swift"), "-o", str(binary))
    (fixture / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.jameslyons.winmux.browser.native-fixture",
        "CFBundleExecutable": "Fixture", "CFBundleName": "WinMux Views Fixture", "CFBundlePackageType": "APPL",
    }))
    run("codesign", "--force", "--sign", os.environ.get("BROWSER_SIGNING_IDENTITY", "-"), str(fixture))
    metadata = {"marker": MARKER, "app": str(app), "helper": str(helper), "fixture": str(binary),
                "helper_sha256": manifest["helper_sha256"],
                "service": "com.jameslyons.winmux.browser.alpha.workspace.test." + str(uuid.uuid4())}
    (directory / "trial.json").write_text(json.dumps(metadata, indent=2) + "\n")
    for action in ["start", "stop"]:
        command = directory / (action.title() + " Trial.command")
        command.write_text("#!/bin/zsh\n" + shlex.join([sys.executable, str(Path(__file__).resolve()), action,
            "--output", str(directory)]) + "\nread -k 1 '?Press any key to close.'\n")
        command.chmod(0o755)
    print("Prepared trial: " + str(directory / "Start Trial.command"))


def check_unowned(path=None):
    path = path or Path(f"/tmp/com.jameslyons.winmux.native-management-{os.getuid()}.lock")
    if path.exists():
        with path.open("r+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Your current workspace is running. Use its Stop Workspace action before starting this trial.") from None
    # The helper independently verifies ownership again before managing anything.


def stop(directory, metadata):
    path = directory / "run.json"
    if not path.exists():
        print("Trial is stopped.")
        return
    state = json.loads(path.read_text())
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/" + metadata["service"]], capture_output=True)
    for key in ["browser", "fixture"]:
        record = state.get(key)
        if record and is_same_process(record):
            os.kill(record["pid"], signal.SIGTERM)
    path.unlink()
    print("Trial stopped. Its separate profile and layout are retained.")


def start(directory, metadata):
    check_unowned()
    helper = Path(metadata["helper"])
    if hashlib.sha256(helper.read_bytes()).hexdigest() != metadata["helper_sha256"]:
        raise RuntimeError("Re-prepare the trial for the updated app")
    if (directory / "run.json").exists():
        raise RuntimeError("Use Stop Trial before starting the same trial again")
    state = {}
    def save():
        (directory / "run.json").write_text(json.dumps(state, indent=2) + "\n")
    service = metadata["service"]
    try:
        with (directory / "fixture.log").open("a") as log:
            fixture = subprocess.Popen([metadata["fixture"], str(directory / "fixture.json")],
                stdout=log, stderr=log, start_new_session=True)
        state["fixture"] = identity(fixture.pid, metadata["fixture"]); save()
        plist = directory / "helper.plist"
        helper_log = directory / "helper.log"
        helper_log.write_text("")
        plist.write_bytes(plistlib.dumps({"Label": service,
            "ProgramArguments": [str(helper), service, str(directory / "inventory.json"), "--manage-native",
                str(directory / "native-state"), "--native-process", str(fixture.pid)],
            "MachServices": {service: True}, "RunAtLoad": True,
            "StandardOutPath": str(helper_log), "StandardErrorPath": str(helper_log)}))
        run("launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist))
        for _ in range(100):
            text = helper_log.read_text()
            if "Native workspace ready" in text:
                break
            if "Native workspace refused:" in text:
                raise RuntimeError(text[-1200:])
            time.sleep(0.2)
        else:
            raise RuntimeError("Trial helper did not become ready; check helper.log and Accessibility permission for the staged helper.")
        executable = Path(metadata["app"]) / "Contents/MacOS/Chromium"
        with (directory / "browser.log").open("a") as log:
            browser = subprocess.Popen([str(executable), "--user-data-dir=" + str(directory / "browser-profile"),
                "--no-first-run", "--no-default-browser-check", "--winmux-sidebar-preview", "--winmux-test-service=" + service,
                "about:blank"], stdout=log, stderr=log, start_new_session=True)
        state["browser"] = identity(browser.pid, executable); save()
        print("Trial running. Use Stop Trial.command when finished, then restart your usual workspace.")
    except BaseException:
        stop(directory, metadata)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "start", "stop", "check"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    directory = args.output.expanduser().resolve()
    if args.action == "prepare":
        if args.app is None:
            parser.error("prepare requires --app")
        prepare(directory, args.app)
        return
    metadata = json.loads((directory / "trial.json").read_text())
    if metadata.get("marker") != MARKER:
        raise RuntimeError("Not a prepared views trial")
    if args.action == "check":
        check_unowned()
        print("No native manager holds the lease.")
    elif args.action == "start":
        start(directory, metadata)
    else:
        stop(directory, metadata)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from None
