#!/usr/bin/env python3
"""Archive a stopped daily WinMux layout; leave the Chromium profile untouched.

The next Workspace Setup start creates fresh native settings and organization.
The archived native-state directory can be restored while the workspace is stopped.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import subprocess
import uuid

SERVICE = "com.jameslyons.winmux.browser.alpha.workspace.managed"
ROOT_MARKER = "winmux-workspace-activation\n"
STATE_MARKER = "isolated-browser-workspace\n"


def checked_path(path):
    if path.resolve() != path.absolute():
        raise RuntimeError("Workspace paths must not contain symlinks")
    if path.exists() and path.stat().st_uid != os.getuid():
        raise RuntimeError("Workspace state belongs to another user")
    return path


def service_is_running(service):
    result = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{service}"],
                            capture_output=True)
    return result.returncode == 0


def archive_layout(root):
    root = checked_path(Path(root).expanduser().absolute())
    marker = checked_path(root / "workspace-activation-v1")
    if marker.read_text() != ROOT_MARKER:
        raise RuntimeError("Requires a marked WinMux Browser workspace root")
    lock_path = checked_path(root / "activation.lock")
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        status_path = checked_path(root / "status.json")
        status = json.loads(status_path.read_text()) if status_path.exists() else {}
        if status.get("helperPID", 0) or status.get("phase") not in (None, "stopped"):
            raise RuntimeError("Stop Workspace before resetting its layout")
        if service_is_running(SERVICE):
            raise RuntimeError("The managed workspace service is still registered")
        request_path = checked_path(root / "request.json")
        request = json.loads(request_path.read_text()) if request_path.exists() else {}
        if request and (request.get("machService") != SERVICE or request.get("validationID")):
            raise RuntimeError("Fresh daily layout cannot reset a fixture workspace")
        state = checked_path(root / "daily/native-state")
        state_marker = checked_path(state / "winmux-browser-state-v1")
        if state_marker.read_text() != STATE_MARKER:
            raise RuntimeError("Requires the marked daily native-state directory")
        for name in ("winmux.toml", "window-state.json", "window-state.json.backup"):
            checked_path(state / name)
        archives = checked_path(root / "layout-archives")
        archives.mkdir(mode=0o700, exist_ok=True)
        name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
        archive = archives / name
        archive.mkdir(mode=0o700)
        report = {"version": 1, "source": str(state), "archive": str(archive / "native-state"),
                  "previousPackage": request.get("browserPath"), "browserProfileRetained": True}
        (archive / "archive.json").write_text(json.dumps(report, indent=2) + "\n")
        os.chmod(archive / "archive.json", 0o600)
        # A single same-filesystem rename archives the entire directory, including
        # backups and any additional native state. Never traverse browser-profile.
        state.rename(archive / "native-state")
        return report
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home() / "Library/Application Support/WinMux Browser Workspace Alpha")
    args = parser.parse_args()
    try:
        report = archive_layout(args.root)
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
