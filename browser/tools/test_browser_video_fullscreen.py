#!/usr/bin/env python3
"""Visible signed-browser video fullscreen regression, with isolated ownership.

Uses pinned MP4/MSE/WebM clips and trusted process-scoped native input. Never
changes an installed package, enrolled service, or existing browser profile.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import subprocess
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit

from test_browser_layout_watchdog import BROWSER_ID, ROOT, stop_process
from test_browser_media import FIXTURES
from test_browser_switch_speed import require_unlocked_session


class VideoFixture:
    def __init__(self, payloads):
        self.lock = threading.Lock()
        self.latest = {}
        self.events = []
        self.errors = []
        self.requests = []
        self.commands = {False: {"sequence": 0}, True: {"sequence": 0}}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                request = urlsplit(self.path)
                if request.path != "/command":
                    with owner.lock:
                        owner.requests.append(request.path)
                if request.path == "/command":
                    peer = parse_qs(request.query).get("peer") == ["true"]
                    with owner.lock:
                        body = json.dumps(owner.commands[peer]).encode()
                    mime = "application/json"
                else:
                    body = payloads.get(request.path)
                    mime = ("text/html; charset=utf-8" if request.path in ("/", "/peer") else
                            "video/webm" if request.path.endswith(".webm") else "video/mp4")
                if body is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self):
                size = int(self.headers.get("Content-Length", "0"))
                if self.path != "/event" or not 0 < size < 65536:
                    self.send_error(400)
                    return
                value = json.loads(self.rfile.read(size))
                if not isinstance(value, dict) or not isinstance(value.get("peer"), bool):
                    self.send_error(400)
                    return
                value["received_monotonic"] = time.monotonic()
                with owner.lock:
                    owner.latest[value["peer"]] = value
                    if value.get("event") != "sample":
                        owner.events.append(value)
                    if value.get("error") or value.get("event") == "fullscreenerror":
                        owner.errors.append(value)
                self.send_response(204)
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def state(self, peer=False):
        with self.lock:
            return dict(self.latest.get(peer, {}))

    def prepare(self, action, peer=False, **extra):
        with self.lock:
            sequence = self.commands[peer]["sequence"] + 1
            self.commands[peer] = dict(sequence=sequence, action=action, **extra)
            return sequence

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def same_frame(actual, expected):
    return bool(actual and expected) and all(abs(actual[k] - expected[k]) <= 2 for k in ("x", "y", "width", "height"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--chromium-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--helper-override", type=Path, help="New diagnostic helper copied and signed separately from the baseline browser")
    parser.add_argument("--cycles", type=int, default=2)
    parser.add_argument("--layouts", nargs="+", choices=("standalone", "stack", "split"), default=["standalone", "stack", "split"])
    parser.add_argument("--media", nargs="+", choices=("mp4", "mse", "webm"), default=["mp4", "mse", "webm"])
    args = parser.parse_args()
    if not 1 <= args.cycles <= 20:
        parser.error("Use 1–20 cycles")
    app = args.app.resolve(strict=True)
    manifest_path = app.parent / "winmux-package-manifest.json"
    manifest = read_json(manifest_path)
    team = manifest.get("team_identifier", "")
    if manifest.get("verified") is not True or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("A verified signed staged alpha package is required")
    executable = app / "Contents/MacOS/Chromium"
    helper = app / manifest["helper_relative_path"]
    for signed, binary, identifier, key in [
        (app, executable, BROWSER_ID, "browser_executable_sha256"),
        (helper, helper, BROWSER_ID + ".workspace", "helper_sha256"),
    ]:
        if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest[key]:
            parser.error("Packaged executable changed after signing")
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, str(signed)], check=True)
    source = args.chromium_source.resolve(strict=True)
    pins = read_json(ROOT / "browser/chromium/pins.json")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != pins["chromium"]["revision"]:
        parser.error("Media fixtures require the pinned Chromium revision")
    payloads = {}
    for name in FIXTURES:
        data = (source / "media/test/data" / name).read_bytes()
        if data != subprocess.check_output(["git", "show", "HEAD:media/test/data/" + name], cwd=source):
            parser.error("Media fixture differs from the pinned source: " + name)
        payloads["/" + name] = data
    html = (ROOT / "browser/tests/fixtures/video_fullscreen.html").read_bytes()
    payloads.update({"/": html, "/peer": html})
    require_unlocked_session()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    identity = manifest["identity_sha1"]
    if args.helper_override:
        helper_app = output / "WinMux Workspace.app"
        subprocess.run(["cp", "-cpR", str(helper.parents[2]), str(helper_app)], check=True)
        helper = helper_app / "Contents/MacOS/WinMuxWorkspaceHelper"
        shutil.copy2(args.helper_override.resolve(strict=True), helper)
        subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", BROWSER_ID + ".workspace",
                        "--options", "runtime", "--timestamp=none", str(helper_app)], check=True)
    probe_app = output / "Fullscreen Input Probe.app"
    probe = probe_app / "Contents/MacOS/fullscreen-input-probe"
    probe.parent.mkdir(parents=True)
    (probe_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": BROWSER_ID + ".workspace", "CFBundleName": "Fullscreen Input Probe",
        "CFBundleExecutable": probe.name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "LSUIElement": True, "NSHighResolutionCapable": True,
    }))
    subprocess.run(["swiftc", "-O", "-module-cache-path", str(output / "module-cache"),
                    str(ROOT / "browser/tools/fullscreen_input_probe.swift"), "-o", str(probe)], check=True)
    subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", BROWSER_ID + ".workspace",
                    "--options", "runtime", "--timestamp=none", str(probe_app)], check=True)
    fixture = VideoFixture(payloads)
    service = BROWSER_ID + ".workspace.test." + str(uuid.uuid4())
    report_path = output / "helper.json"
    command_path = output / "fullscreen-command.json"
    plist = output / "helper.plist"
    plist.write_bytes(plistlib.dumps({"Label": service, "ProgramArguments": [str(helper), service, str(report_path)],
        "MachServices": {service: True}, "RunAtLoad": True, "ProcessType": "Interactive",
        "EnvironmentVariables": {"WINMUX_TEST_VIDEO_FULLSCREEN": "1",
                                 "WINMUX_TEST_PROFILE_URL": f"http://127.0.0.1:{fixture.server.server_port}/"},
        "StandardOutPath": str(output / "helper.log"), "StandardErrorPath": str(output / "helper.log")}))
    command = [str(executable), "--user-data-dir=" + str(output / "profile"), "--profile-directory=Default",
        "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1", "--enable-logging=stderr",
        "--force-renderer-accessibility", "--winmux-sidebar-preview", "--winmux-test-service=" + service,
        "--winmux-bridge-report=" + str(output / "bridge.json"), "about:blank"]
    result = dict(passed=False, scope="isolated_visible_managed_video_fullscreen", command=command,
        package_manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(), fixture_chromium_revision=revision,
        fixtures_sha256={name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()},
        samples=[], native_cases=[], limits=["Local pinned clips; no remote sites or extensions", "Existing workspace and profiles preserved"])
    browser = input_probe = None
    bootstrapped = False
    selector = selectors.DefaultSelector()
    sequence = 0
    try:
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True, timeout=10)
        bootstrapped = True
        with (output / "browser.log").open("x") as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)

        def wait(predicate, timeout=15):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if browser.poll() is not None:
                    raise RuntimeError(f"Browser exited during fullscreen test: {browser.returncode}")
                with fixture.lock:
                    errors = list(fixture.errors)
                if errors:
                    raise RuntimeError("Fixture error: " + json.dumps(errors))
                value = predicate()
                if value:
                    return value
                time.sleep(.025)
            raise TimeoutError("Fullscreen fixture condition timed out")

        def control(action, peer=False):
            nonlocal sequence
            sequence += 1
            temporary = command_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(dict(sequence=sequence, action=action, peer=peer)))
            temporary.replace(command_path)
            expected = f"{sequence}:issued"
            wait(lambda: read_json(report_path).get("outcomes", {}).get("video_command") == expected)

        wait(lambda: read_json(report_path).get("outcomes", {}).get("video_fullscreen") == "ready", timeout=45)
        ids = read_json(report_path)["outcomes"]
        seed, peer_id = ids["video_surface"], ids["video_peer"]

        def hosts():
            return {h["surface_id"]: h for h in read_json(report_path).get("hosts", [])}

        # Hidden native hosts defer media loading. Initialize both players while
        # their managed split windows are visible before testing other layouts.
        control("split")
        wait(lambda: fixture.state().get("event") == "sample" and fixture.state(True).get("event") == "sample")
        input_probe = subprocess.Popen([str(probe), str(browser.pid)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=(output / "input.log").open("x"), text=True, bufsize=1)
        selector.register(input_probe.stdout, selectors.EVENT_READ)

        def key(action):
            input_probe.stdin.write(action + "\n")
            input_probe.stdin.flush()
            if not selector.select(5):
                raise TimeoutError("Process-scoped input probe timed out")
            outcome = input_probe.stdout.readline().strip()
            if outcome != ("ready" if action == "status" else "posted"):
                raise RuntimeError("Process-scoped input unavailable: " + outcome)

        control("focus")
        key("status")
        key("page")

        def player(action, peer=False, **extra):
            result["phase"] = dict(action=action, peer=peer, **extra)
            seq = fixture.prepare(action, peer, **extra)
            if action == "load":
                wait(lambda: fixture.state(peer).get("completed") == seq and fixture.state(peer).get("frames", 0) > 0)
            else:
                wait(lambda: fixture.state(peer).get("prepared") == seq)
                key("input")
                wait(lambda: fixture.state(peer).get("completed") == seq)
            return fixture.state(peer)

        def progress(peer=False):
            before = fixture.state(peer)
            wait(lambda: fixture.state(peer).get("frames", 0) >= before.get("frames", 0) + 5
                 and fixture.state(peer).get("audioBytes", 0) > 0 and not fixture.state(peer).get("paused"), timeout=10)
            return dict(before=before, after=fixture.state(peer))

        player("load", True, kind="webm")
        for layout in args.layouts:
            control(layout)
            control("focus")
            key("page")
            wait(lambda: hosts().get(seed, {}).get("managed") is True)
            saved = hosts()
            for kind in args.media:
                player("load", kind=kind)
                for cycle in range(args.cycles):
                    sample = dict(layout=layout, kind=kind, cycle=cycle, before=hosts())
                    result["samples"].append(sample)
                    player("enter")
                    wait(lambda: hosts().get(seed, {}).get("fullscreen") is True)
                    # Native entry is asynchronous: allow the Space animation to
                    # settle before attempting to focus a window on another Space.
                    time.sleep(1)
                    sample["during"] = hosts()
                    sample["fullscreen_playback"] = progress()
                    if not fixture.state().get("fullscreen"):
                        raise RuntimeError("Video did not remain fullscreen")
                    if sample["during"][seed]["native_window_id"] != saved[seed]["native_window_id"]:
                        raise RuntimeError("Fullscreen replaced the managed host")
                    control("peer-layout")
                    wait(lambda: hosts().get(seed, {}).get("fullscreen") is True)
                    if cycle % 2:
                        sample["exit_method"] = "escape"
                        key("escape")
                        wait(lambda: fixture.state().get("fullscreen") is False)
                    else:
                        sample["exit_method"] = "native_video_player_exit_control"
                        key("player-exit")
                        wait(lambda: fixture.state().get("fullscreen") is False)
                    wait(lambda: hosts().get(seed, {}).get("fullscreen") is False)
                    wait(lambda: same_frame(hosts().get(seed, {}).get("frame"), saved[seed]["frame"])
                         and hosts().get(seed, {}).get("managed") is True)
                    sample["after"] = hosts()
                    sample["restored_playback"] = progress()
                    if sample["after"][seed]["native_window_id"] != saved[seed]["native_window_id"]:
                        raise RuntimeError("Fullscreen exit replaced the managed host")
                    control(layout)
                    control("focus")
                    key("page")
                    if layout == "split":
                        control("focus", True)
                        key("page")
                        player("load", True, kind="webm")
                        player("ack", True)
                        sample["peer_playback"] = progress(True)
                        control("focus")
                        key("page")

        control("standalone")
        control("focus")
        key("page")
        key("green")
        wait(lambda: hosts().get(seed, {}).get("fullscreen") is True)
        time.sleep(1)
        player("enter")
        result["native_cases"].append(dict(case="green_button_and_video_inside_native_fullscreen", playback=progress()))
        player("exit")
        if hosts().get(seed, {}).get("fullscreen") is not True:
            raise RuntimeError("Exiting video lost preexisting native fullscreen")
        control("fullscreen")
        wait(lambda: hosts().get(seed, {}).get("fullscreen") is False)
        control("standalone")
        control("focus")
        key("page")
        player("enter")
        wait(lambda: hosts().get(seed, {}).get("fullscreen") is True)
        time.sleep(1)
        # Release ownership while fullscreen is still active. A posted exit
        # restoration must not reclaim a page the workspace has released.
        control("release")
        player("exit")
        wait(lambda: hosts().get(seed, {}).get("fullscreen") is False)
        wait(lambda: hosts().get(seed, {}).get("managed") is False)
        result["native_cases"].append(dict(case="release_during_fullscreen", host=hosts()[seed]))
        control("standalone")
        control("focus")
        key("page")
        player("enter")
        wait(lambda: hosts().get(seed, {}).get("fullscreen") is True)
        time.sleep(1)
        control("close")
        wait(lambda: seed not in hosts())
        # Removal from inventory precedes AppKit's fullscreen Space teardown.
        # Let that animation finish before focusing the surviving peer.
        time.sleep(1)
        control("focus", True)
        key("page")
        player("ack", True)
        result["native_cases"].append(dict(case="close_fullscreen_page", remaining_hosts=hosts()))
        result["passed"] = True
    except (Exception, KeyboardInterrupt) as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        result["browser_exit_before_cleanup"] = browser.poll() if browser else None
        selector.close()
        result["input_cleanup"] = stop_process(input_probe)
        result["browser_cleanup"] = stop_process(browser)
        result["browser_exit_after_cleanup"] = browser.poll() if browser else None
        if bootstrapped:
            result["test_service_removed"] = subprocess.run(
                ["launchctl", "bootout", f"gui/{os.getuid()}/{service}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
        with fixture.lock:
            result["events"] = fixture.events
            result["requests"] = fixture.requests
            result["last_page_states"] = {str(k): v for k, v in fixture.latest.items()}
        fixture.close()
        result["last_inventory"] = read_json(report_path)
        log = (output / "browser.log").read_text(errors="replace") if (output / "browser.log").exists() else ""
        fatal = re.search(r"(?:FATAL|Check failed|CHECK failed|DCHECK failed|Received signal).*", log, re.DOTALL)
        if fatal:
            (output / "crash-stack.txt").write_text(fatal.group()[:65536])
            result["crash_stack"] = str(output / "crash-stack.txt")
            result["passed"] = False
            result.setdefault("error", "Native crash stack captured during test or cleanup")
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result.get(k) for k in ("passed", "error", "browser_exit_before_cleanup", "crash_stack", "test_service_removed")}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
