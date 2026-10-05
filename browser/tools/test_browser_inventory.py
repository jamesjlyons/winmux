#!/usr/bin/env python3
"""Test signed browser inventory/actions through an isolated launchd service.

The existing SMAppService enrollment and installed browser remain untouched.
Only fresh isolated test tabs are navigated, arranged, focused, and closed.
Native window controls use an explicitly requested visible fixture. All artifacts stay in a new
directory; the test service is booted out and its own browser stopped on exit.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sqlite3
import threading
import time
import uuid

from measure_helper import Sampler


def identity(sample):
    return sample["process_start_ticks"], sample["executable_uuid"]


class ProfileFixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        names = {"/work": "work", "/work-return": "work", "/personal": "personal", "/shared": "shared"}
        account = names.get(self.path)
        self.send_response(200 if account else 404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        if account:
            self.server.observations.append({"path": self.path, "cookie": self.headers.get("Cookie", "")})
            self.send_header("Set-Cookie", f"winmux_fixture={account}; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax")
        body = f"<!doctype html><title>Profile fixture</title><p>{account or 'missing'}</p>".encode()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def verify_profile_storage(profile_root, observations, resumed):
    expected = {"/work": "winmux_fixture=work" if resumed else "",
                "/personal": "winmux_fixture=personal" if resumed else "",
                "/work-return": "winmux_fixture=work",
                "/shared": "winmux_fixture=shared" if resumed else ""}
    assert all(any(item == {"path": path, "cookie": cookie} for item in observations) for path, cookie in expected.items())
    assert all(item["cookie"] == expected[item["path"]] or
               item["cookie"] == "winmux_fixture=" + {"/work-return": "work"}.get(item["path"], item["path"].lstrip("/"))
               for item in observations), "A page received another profile's cookie"
    profiles = {"work": "WinMux Profile 502aa58c-4c74-422e-9b41-e0a2fbbfc001",
                "personal": "WinMux Profile 502aa58c-4c74-422e-9b41-e0a2fbbfc002", "shared": "Default"}
    history = {}
    for name, directory in profiles.items():
        root = profile_root / directory
        assert root.is_dir() and not root.is_symlink()
        with sqlite3.connect(f"file:{root / 'History'}?mode=ro", uri=True) as database:
            urls = [row[0] for row in database.execute("select url from urls")]
        fixture_urls = [url for url in urls if url.startswith("http://127.0.0.1:")]
        allowed = {"/work", "/work-return"} if name == "work" else {"/" + name}
        from urllib.parse import urlsplit
        assert fixture_urls and all(urlsplit(url).path in allowed for url in fixture_urls), "History crossed profile boundaries"
        preferences = json.loads((root / "Preferences").read_text())
        if name != "shared":
            assert preferences["winmux"]["profile_uuid"] == directory.removeprefix("WinMux Profile ")
        history[name] = len(fixture_urls)
    return {"cookies_isolated": True, "history_isolated": True, "history_entries": history, "resumed": resumed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--existing-helper-pid", type=int, required=True)
    parser.add_argument("--existing-helper-executable", type=Path, required=True)
    parser.add_argument("--resume-profiles-from", type=Path,
                        help="Reuse only a previously successful, stopped synthetic fixture to verify profile restart")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--private", action="store_true", help="Verify private tabs never enter helper inventory")
    modes.add_argument("--native-window-controls", action="store_true",
                       help="Use visible isolated native windows to verify minimize, fullscreen, zoom and restoration")
    args = parser.parse_args()
    profile_root = None
    if args.resume_profiles_from:
        previous = args.resume_profiles_from.resolve(strict=True)
        record = json.loads((previous / "result.json").read_text())
        profile_root = previous / "profile"
        if (args.private or args.native_window_controls or record.get("passed") is not True or
                record.get("test_service_removed") is not True or record.get("browser_exit_code") != 0 or
                record.get("profile_isolation", {}).get("cookies_isolated") is not True or
                "--user-data-dir=" + str(profile_root) not in record.get("command", []) or
                not profile_root.is_dir() or profile_root.is_symlink()):
            parser.error("Resume requires a successful stopped synthetic profile fixture")
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
    profile_root = profile_root or output / "profile"
    server = ThreadingHTTPServer(("127.0.0.1", 0), ProfileFixture)
    server.observations = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    service = browser_id + ".workspace.test." + str(uuid.uuid4())
    helper_report = output / "helper.json"
    bridge_report = output / "bridge.json"
    plist = output / "test-helper.plist"
    helper_arguments = [str(helper), service, str(helper_report)]
    if args.native_window_controls:
        helper_arguments.append("--window-controls")
    plist.write_bytes(plistlib.dumps({"Label": service, "ProgramArguments": helper_arguments,
        "EnvironmentVariables": {"WINMUX_TEST_PROFILE_URL": f"http://127.0.0.1:{server.server_port}/"},
        "MachServices": {service: True}, "RunAtLoad": True,
        "StandardOutPath": str(output / "helper.log"), "StandardErrorPath": str(output / "helper.log")}))
    command = [str(executable), "--user-data-dir=" + str(profile_root), "--profile-directory=Default",
               "--no-first-run", "--no-default-browser-check", "--enable-logging=stderr",
               "--winmux-bridge-report=" + str(bridge_report), "--winmux-test-service=" + service,
               "--winmux-trace-layout"]
    command += (["--winmux-sidebar-preview"] if args.native_window_controls else
                ["--headless=new", "--winmux-bridge-test-disconnect-once"])
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
                "layout_repeated_group_switches": "20", "layout_repeated_group_restore": "yes",
                "navigation_legacy_rejected": "unsupported", "navigate_first": "issued", "navigate_second": "issued",
                "navigate_repeat": "issued", "navigate_payload_conflict": "operation_conflict",
                "navigate_stale_revision": "stale_revision", "navigate_invalid_url": "invalid_request",
                "back": "issued", "back_state": "yes", "forward": "issued", "forward_state": "yes",
                "reload": "issued", "stop": "issued", "navigation_keeps_native_windows": "yes",
                "new_tab": "issued", "new_tab_independent_native_window": "yes", "new_tab_close": "issued"}
    expected.update({"create_close_last": "issued", "create_empty_inventory": "yes",
                     "create_foreign_epoch": "stale_epoch", "create_stale_revision": "stale_revision",
                     "create_invalid_url": "invalid_request", "create_unknown_profile": "unavailable",
                     "create_from_empty": "issued", "create_exact_identity": "yes", "create_repeat": "issued",
                     "create_repeat_same_identity": "yes", "create_operation_conflict": "operation_conflict",
                     "create_cross_action_conflict": "operation_conflict", "create_repeat_no_duplicate": "yes",
                     "create_close_created": "issued", "create_global_from_empty": "issued", "create_global_exact_identity": "yes",
                     "create_global_repeated_reopen": "yes"})
    expected.update({"profiles_invalid_key": "invalid_request", "profiles_repeat": "yes",
                     "profiles_conflict": "operation_conflict", "profiles_cleanup": "yes",
                     **{f"profiles_open_{index}": "yes" for index in range(4)}})
    if args.native_window_controls:
        expected.update({
                "native_minimize": "issued", "native_minimize_state": "yes",
                "native_minimize_peer_layout": "issued", "native_minimize_survives_layout": "yes",
                "native_minimize_keeps_window_ids": "yes", "native_restore_focus": "issued",
                "native_restore_state": "yes", "native_restore_layout": "issued", "native_restore_frames": "yes",
                "native_fullscreen_enter": "issued", "native_fullscreen_state": "yes",
                "native_fullscreen_peer_layout": "issued", "native_fullscreen_survives_layout": "yes",
                "native_fullscreen_keeps_window_ids": "yes", "native_fullscreen_exit": "issued",
                "native_fullscreen_exit_state": "yes", "native_fullscreen_return_layout": "issued",
                "native_fullscreen_returns_to_tiles": "yes", "native_window_actions_keep_surfaces": "yes",
                "native_zoom_enter": "issued", "native_zoom_state": "yes", "native_zoom_peer_layout": "issued",
                "native_zoom_survives_layout": "yes", "native_zoom_keeps_window_ids": "yes", "native_zoom_exit": "issued",
                "native_zoom_exit_state": "yes", "native_zoom_return_layout": "issued", "native_zoom_returns_to_tiles": "yes",
        })
    expected_count = 0 if args.private else 1
    if args.private:
        expected = {}
    fixture_description = ("Visible synthetic native windows; no native window manager is launched" if args.native_window_controls else
                           "Headless synthetic tabs; focus acknowledgement is not UI/input-ready confirmation")
    result = {"scope": ("actual_signed_browser_protocol6_native_window_controls" if args.native_window_controls else
                        "actual_signed_browser_protocol6_page_windows_profiles"), "passed": False,
        "package_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "test_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "command": command, "service": service, "private_inventory_test": args.private,
        "native_window_controls_test": args.native_window_controls, "observations": [],
        "limits": [fixture_description,
                   "No native window manager or shared sidebar is launched",
                   "Existing browser profiles, helper enrollment and signed-in UI are preserved"]}
    process, bootstrapped = None, False
    with (output / "browser.log").open("x") as log:
        try:
            subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True)
            bootstrapped = True
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            start, previous, recovered_at, completed_at = time.monotonic(), None, None, None
            while time.monotonic() - start < 45:
                if process.poll() is not None:
                    raise RuntimeError(f"Test browser exited early: {process.returncode}")
                if helper_report.exists() and bridge_report.exists():
                    report = json.loads(helper_report.read_text())
                    bridge = json.loads(bridge_report.read_text())
                    if report != previous:
                        result["observations"].append({"elapsed_seconds": time.monotonic() - start, "helper": report})
                        previous = report
                    actions_complete = (bridge.get("authenticated_connections") == 1 and
                                        report.get("outcomes") == expected and report.get("tab_count") == expected_count)
                    if actions_complete:
                        result["actions"] = report
                    if args.native_window_controls:
                        if (actions_complete and bridge.get("state") == "authenticated" and bridge.get("protocol_version") == 6
                                and report.get("full_messages") == 1):
                            if completed_at is None:
                                completed_at = time.monotonic()
                            if time.monotonic() - completed_at >= 2:
                                result.update(bridge=bridge, helper=report, seconds_after_completion=time.monotonic()-completed_at)
                                result["passed"] = report.get("delta_messages", 0) >= 2
                                break
                        elif completed_at is not None:
                            raise RuntimeError("Completed native window controls did not remain stable")
                        time.sleep(.1)
                        continue
                    if ("actions" in result and bridge.get("state") == "authenticated" and bridge.get("protocol_version") == 6
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
                result["error"] = "Expected protocol6 isolated fixture outcomes were not observed"
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
            server.shutdown()
            server.server_close()
            result["profile_cookie_observations"] = server.observations
            if result["passed"] and not args.private:
                try:
                    result["profile_isolation"] = verify_profile_storage(profile_root, server.observations, bool(args.resume_profiles_from))
                except (AssertionError, OSError, KeyError, sqlite3.Error) as error:
                    result.update(passed=False, error="Profile storage verification failed: " + str(error))
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: result.get(key) for key in ("passed", "helper", "existing_helper_unchanged", "test_service_removed", "error")}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
