#!/usr/bin/env python3
"""Verify layout reply-loss recovery through the real isolated workspace controller.

Requires a signed staged package and an unowned native-management lease. Creates
only fresh fixture windows, profile, state, and a UUID launchd service. Never
stops an existing manager or touches an enrolled service or existing profile.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import socket
import stat
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
BROWSER_ID = "com.jameslyons.winmux.browser.alpha"
DROP = re.compile(r"WinMux layout: test_dropped_reply generation=(\d+)")


def require_free_native_lease():
    path = f"/tmp/com.jameslyons.winmux.native-management-{os.getuid()}.lock"
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
            raise RuntimeError("Native-management lease is not an owned regular file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("A native manager is active; this test will not stop it") from None
    finally:
        os.close(descriptor)


def request(endpoint, arguments):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect(str(endpoint))
        payload = json.dumps(dict(args=arguments, stdin="", windowId=None, workspace=None)).encode()
        connection.sendall(struct.pack("<I", len(payload)) + payload)

        def receive(length):
            data = b""
            while len(data) < length:
                chunk = connection.recv(length - len(data))
                if not chunk:
                    raise RuntimeError("Workspace socket closed before its complete reply")
                data += chunk
            return data

        length = struct.unpack("<I", receive(4))[0]
        if length > 4 * 1024 * 1024:
            raise RuntimeError("Workspace reply exceeds diagnostic limit")
        reply = json.loads(receive(length))
        if reply["exitCode"]:
            raise RuntimeError(reply["stderr"])
        return reply["stdout"]


def browser_rows(rows):
    return [row for row in rows if row.get("available") and "browser" in row]


def wait_for_workspace_socket(endpoint, timeout=20, *, clock=time.monotonic, sleep=time.sleep):
    # Binding creates the pathname before the helper necessarily accepts IPC.
    # Retry only these startup races; validation after launch never retries a
    # transport failure or sends a mutating request to establish readiness.
    deadline = clock() + timeout
    while True:
        try:
            rows = json.loads(request(endpoint, ["surface", "list"]))
            if not isinstance(rows, list):
                raise RuntimeError("Workspace readiness returned an invalid surface inventory")
            return
        except (FileNotFoundError, ConnectionRefusedError) as error:
            if clock() >= deadline:
                raise RuntimeError("Scoped native helper socket did not become ready; inspect helper.log") from error
            sleep(.025)


def require_pending_replacement(rows, surface, workspace, dropped_generation):
    tabs = browser_rows(rows)
    assert len(tabs) == 1 and tabs[0]["id"] == surface, "Fixture browser identity changed"
    tab, state = tabs[0], tabs[0]["browser"]
    assert tab["workspace"] == workspace and tab["selected"], "New group was not selected"
    assert state.get("layoutGeneration") == dropped_generation, "Replacement missed the pending-request interval"
    assert state.get("layoutReply") is None and state.get("pendingLayoutMilliseconds") is not None, "No pending lost reply"
    assert state.get("layoutTimeoutCount") == 0, "Watchdog fired before the replacement was requested"


def require_recovered(rows, surface, workspace, window_id, dropped_generation):
    tabs = browser_rows(rows)
    assert len(tabs) == 1 and tabs[0]["id"] == surface, "Fixture browser identity changed"
    tab, state = tabs[0], tabs[0]["browser"]
    assert tab["workspace"] == workspace and tab["selected"], "Latest group/selection was lost"
    assert state.get("layoutTimeoutCount") == 1, "Expected exactly one lost-reply timeout"
    assert state.get("layoutReply") == "issued" and state.get("pendingLayoutMilliseconds") is None, "Recovery is not acknowledged"
    assert state.get("layoutGeneration", 0) > dropped_generation, "No newer layout was acknowledged"
    assert state.get("managed") is True and state.get("requestedVisible") is True, "Latest layout is not visible and managed"
    assert state.get("hostWindowID") == window_id, "Recovery replaced the native browser window"
    frame = state.get("requestedFrame")
    assert frame and state.get("frame") == frame, "Observed frame differs from the newest requested frame"
    return frame


def read_snapshot(observer, ready, browser_pid):
    observer.stdin.write(b"snapshot\n")
    observer.stdin.flush()
    line, deadline = b"", time.monotonic() + 3
    while not line.endswith(b"\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not ready.select(remaining):
            raise RuntimeError("WindowServer observer timed out")
        chunk = os.read(observer.stdout.fileno(), 65536)
        if not chunk:
            raise RuntimeError("WindowServer observer exited")
        line += chunk
    return {str(window["id"]): window["bounds"] for window in json.loads(line)
            if window["pid"] == browser_pid and window["onscreen"]}


def require_stable_window_frames(capture, expected, result, start, *, settling_seconds=3,
                                 stable_seconds=2, clock=time.monotonic, sleep=time.sleep):
    # An owner acknowledgement precedes WindowServer's presentation commit.
    # Permit only a bounded initial transition; any later mismatch fails.
    # Chromium also owns auxiliary layer-zero windows (e.g. status bubbles).
    # Anchor geometry to the original inventory host IDs; retain other windows
    # as evidence instead of treating every process window as a managed page.
    deadline, matched_at = clock() + settling_seconds, None
    result["settling_window_snapshots"] = []
    result["stable_window_snapshots"] = []
    while True:
        process_windows = capture()
        actual = {window_id: bounds for window_id, bounds in process_windows.items() if window_id in expected}
        sampled_at = clock()
        snapshot = dict(response_seconds=sampled_at - start, frames=actual,
                        other_browser_windows={window_id: bounds for window_id, bounds in process_windows.items()
                                               if window_id not in expected})
        if matched_at is None:
            result["settling_window_snapshots"].append(snapshot)
            if sampled_at > deadline:
                raise AssertionError("WindowServer did not reach the recovered plan within the settling deadline")
            if actual == expected:
                matched_at = sampled_at
                result["matching_geometry_observed_seconds"] = sampled_at - start
                result["stable_window_snapshots"].append(snapshot)
        else:
            result["stable_window_snapshots"].append(snapshot)
            assert actual == expected, "WindowServer frame/visibility changed after reaching the recovered plan"
            if sampled_at - matched_at >= stable_seconds:
                return
        sleep(.1)


def stop_process(process):
    if process is None or process.poll() is not None:
        return True
    process.terminate()
    try:
        process.wait(timeout=10)
        return True
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
        return False


def cleanup_fixture(result, ready, observer, browser, fixture, service, bootstrap_attempted):
    """Attempt every scoped cleanup step even if another step fails or hangs."""
    def remove_service():
        if not bootstrap_attempted:
            return True
        return subprocess.run(
            ["launchctl", "bootout", f"gui/{os.getuid()}/{service}"],
            capture_output=True, timeout=10,
        ).returncode == 0

    steps = (
        ("observer_selector_closed", ready.close),
        ("observer_stopped_cleanly", lambda: stop_process(observer)),
        ("browser_stopped_cleanly", lambda: stop_process(browser)),
        ("test_service_removed", remove_service),
        ("fixture_stopped_cleanly", lambda: stop_process(fixture)),
    )
    for key, action in steps:
        try:
            result[key] = action() is not False
        except (Exception, KeyboardInterrupt) as error:
            result[key] = False
            result.setdefault("cleanup_errors", {})[key] = f"{type(error).__name__}: {error}"
    return all(result[key] for key, _ in steps)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory for all fixture state and evidence")
    args = parser.parse_args()
    if not __debug__:
        parser.error("Run without Python -O: fixture assertions must remain enabled")
    app = args.app.resolve(strict=True)
    manifest_path = app.parent / "winmux-package-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    team = manifest.get("team_identifier", "")
    if manifest.get("verified") is not True or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("A verified signed staged alpha package is required")
    executable = app / "Contents/MacOS/Chromium"
    helper = app / manifest["helper_relative_path"]
    for path, binary, identifier, key in [
        (app, executable, BROWSER_ID, "browser_executable_sha256"),
        (helper, helper, BROWSER_ID + ".workspace", "helper_sha256"),
    ]:
        if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest.get(key):
            parser.error("Packaged executable changed after signing")
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, str(path)], check=True)
    require_free_native_lease()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture_app = output / "Native Fixture.app/Contents"
    (fixture_app / "MacOS").mkdir(parents=True)
    fixture_binary = fixture_app / "MacOS/NativeWindowFixture"
    (fixture_app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.jameslyons.winmux.fixture." + str(uuid.uuid4()),
        "CFBundleExecutable": "NativeWindowFixture", "CFBundleName": "WinMux Test Fixture",
        "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication",
    }))
    for source, destination in [
        (ROOT / "browser/tools/native_window_fixture.swift", fixture_binary),
        (ROOT / "script/benchmarks/group-window-observer.swift", output / "window-observer"),
    ]:
        subprocess.run(["swiftc", "-O", "-module-cache-path", str(output / "module-cache"),
                        str(source), "-o", str(destination)], check=True)
    service = BROWSER_ID + ".workspace.test." + str(uuid.uuid4())
    native_state = output / "native-state"
    digest = hashlib.sha256(str(native_state).encode()).hexdigest()[:24]
    endpoint = Path(f"/tmp/winmux-browser-{os.getuid()}-{digest}.sock")
    command = [str(executable), "--user-data-dir=" + str(output / "profile"),
               "--no-first-run", "--no-default-browser-check", "--enable-logging=stderr",
               "--winmux-sidebar-preview", "--winmux-test-service=" + service,
               "--winmux-bridge-report=" + str(output / "bridge.json"), "--winmux-trace-layout",
               "--winmux-test-drop-layout-reply-once", "about:blank#layout-watchdog"]
    result = dict(scope="signed_isolated_workspace_layout_watchdog", passed=False, command=command,
                  service=service, observations=[],
                  package_manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                  test_source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  limits=["Fresh synthetic browser/native windows only; native discovery is scoped to the fixture PID.",
                          "Tests acknowledgement recovery and WindowServer frames, not rendered page or input readiness.",
                          "Geometry targets the original inventory-reported managed host IDs; other browser windows are recorded separately.",
                          "Acknowledgement is not presentation: allow up to 3 seconds for matching geometry, then require 2 seconds of exact stable samples.",
                          "Snapshot timestamps are taken after receipt and are observation upper bounds."])
    fixture = browser = observer = None
    ready, bootstrap_attempted = selectors.DefaultSelector(), False
    start = time.monotonic()
    with (output / "browser.log").open("x") as browser_log, (output / "fixture.log").open("x") as fixture_log:
        try:
            fixture_report = output / "fixture.json"
            fixture = subprocess.Popen([str(fixture_binary), str(fixture_report)], stdout=fixture_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 10
            while True:
                if fixture.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Native fixture did not become ready")
                if fixture_report.exists():
                    fixture_ids = {window["window_id"] for window in json.loads(fixture_report.read_text())["windows"]}
                    if len(fixture_ids) == 2:
                        break
                time.sleep(.025)
            result["native_fixture_pid"] = fixture.pid
            plist = output / "test-helper.plist"
            plist.write_bytes(plistlib.dumps({"Label": service, "ProgramArguments": [str(helper), service,
                str(output / "helper.json"), "--manage-native", str(native_state), "--native-process", str(fixture.pid)],
                "MachServices": {service: True}, "RunAtLoad": True, "ProcessType": "Interactive",
                "StandardOutPath": str(output / "helper.log"), "StandardErrorPath": str(output / "helper.log")}))
            # Even a failed/timed-out bootstrap can have registered the unique
            # service, so always attempt its scoped removal once called.
            bootstrap_attempted = True
            subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True, timeout=10)
            wait_for_workspace_socket(endpoint)
            browser = subprocess.Popen(command, stdout=browser_log, stderr=subprocess.STDOUT, start_new_session=True)
            result["browser_pid"] = browser.pid

            def observe():
                if browser.poll() is not None or fixture.poll() is not None:
                    raise RuntimeError("A fixture process exited before validation")
                rows = json.loads(request(endpoint, ["surface", "list"]))
                native_ids = {row["nativeWindowID"] for row in rows if row.get("nativeWindowID")}
                assert native_ids <= fixture_ids, "Native discovery escaped the fixture process"
                result["observations"].append(dict(response_seconds=time.monotonic() - start, surfaces=rows))
                return rows

            deadline = time.monotonic() + 20
            while True:
                drops = DROP.findall((output / "browser.log").read_text())
                rows = observe()
                tabs = browser_rows(rows)
                if drops and len(tabs) == 1 and tabs[0]["browser"].get("hostWindowID"):
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError("Did not observe a deliberately dropped layout reply and live fixture tab")
                time.sleep(.01)
            assert len(drops) == 1, "Expected one injected reply loss"
            dropped_generation = int(drops[0])
            surface, window_id = tabs[0]["id"], tabs[0]["browser"]["hostWindowID"]
            workspace = "WatchdogLatest"
            request(endpoint, ["surface", "move", surface, workspace, "--focus-follows-surface"])
            require_pending_replacement(observe(), surface, workspace, dropped_generation)
            result.update(dropped_generation=dropped_generation, newest_group_requested_while_pending=True)
            # From this point onward use read-only observations. No second
            # layout command, focus poke, or reconnect may drive the recovery.
            deadline, last_error = time.monotonic() + 8, None
            while time.monotonic() < deadline:
                rows = observe()
                try:
                    frame = require_recovered(rows, surface, workspace, window_id, dropped_generation)
                    break
                except AssertionError as error:
                    last_error = error
                time.sleep(.025)
            else:
                raise RuntimeError(f"Watchdog did not recover automatically: {last_error}")
            result["automatic_recovery_observed_seconds"] = time.monotonic() - start
            observer = subprocess.Popen([str(output / "window-observer")], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, bufsize=0)
            ready.register(observer.stdout, selectors.EVENT_READ)
            expected = {str(window_id): dict(X=frame["x"], Y=frame["y"], Width=frame["width"], Height=frame["height"])}
            result["expected_frames"] = expected

            def capture_geometry():
                assert require_recovered(observe(), surface, workspace, window_id, dropped_generation) == frame, "Recovered frame drifted"
                return read_snapshot(observer, ready, browser.pid)

            require_stable_window_frames(capture_geometry, expected, result, start)
            bridge = json.loads((output / "bridge.json").read_text())
            assert bridge.get("state") == "authenticated" and bridge.get("authenticated_connections") == 1, "Recovery reconnected instead of retrying"
            assert len(DROP.findall((output / "browser.log").read_text())) == 1, "Reply loss was injected more than once"
            result.update(passed=True, timeout_count=1, expected_frames=expected, bridge=bridge)
        except (Exception, KeyboardInterrupt) as error:
            result["error"] = f"{type(error).__name__}: {error}"
        finally:
            cleaned = cleanup_fixture(result, ready, observer, browser, fixture, service, bootstrap_attempted)
            result["browser_exit_code"] = browser.returncode if browser else None
            result["fixture_exit_code"] = fixture.returncode if fixture else None
            result["passed"] = result["passed"] and cleaned
            result["elapsed_seconds"] = time.monotonic() - start
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result.get(key) for key in ("passed", "timeout_count", "test_service_removed", "error")}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
