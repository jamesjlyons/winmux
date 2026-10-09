#!/usr/bin/env python3
"""Click and exercise the integrated page menu in an isolated signed browser."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import subprocess
import threading
import time
import uuid

from test_browser_switch_speed import require_unlocked_session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require_unlocked_session()
    app = args.app.resolve(strict=True)
    manifest_path = app.parent / "winmux-package-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    assert manifest["verified"]
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest(app / "Contents/MacOS/Chromium") == manifest["browser_executable_sha256"]
    assert digest(app / manifest["helper_relative_path"]) == manifest["helper_sha256"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    probe = output / "page-menu-probe"
    subprocess.run(["xcrun", "swiftc", str(Path(__file__).with_name("page_menu_probe.swift")),
                    "-o", str(probe)], check=True)

    class Page(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            body = b"<!doctype html><title>Page menu fixture</title><p>Local menu regression</p>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    service = "com.jameslyons.winmux.browser.alpha.workspace.test." + str(uuid.uuid4())
    report_file = output / "helper.json"
    plist = output / "helper.plist"
    plist.write_bytes(plistlib.dumps({
        "Label": service,
        "ProgramArguments": [str(app / manifest["helper_relative_path"]), service, str(report_file)],
        "MachServices": {service: True}, "RunAtLoad": True, "ProcessType": "Interactive",
        "EnvironmentVariables": {"WINMUX_TEST_VIDEO_FULLSCREEN": "1",
                                 "WINMUX_TEST_PROFILE_URL": f"http://127.0.0.1:{server.server_port}/"},
        "StandardOutPath": str(output / "helper.log"), "StandardErrorPath": str(output / "helper.log"),
    }))
    result = {"passed": False, "scope": "signed_browser_native_page_menu", "cases": [],
              "package_manifest_sha256": digest(manifest_path),
              "fixture_sha256": digest(Path(__file__)),
              "probe_sha256": digest(Path(__file__).with_name("page_menu_probe.swift"))}
    browser = None
    bootstrapped = False
    sequence = 0

    def report():
        try:
            return json.loads(report_file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def wait(predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if browser and browser.poll() is not None:
                raise RuntimeError(f"Fixture browser exited: {browser.returncode}")
            if predicate():
                return
            time.sleep(.05)
        raise TimeoutError("Fixture condition timed out")

    def control(action):
        nonlocal sequence
        sequence += 1
        temporary = output / "fullscreen-command.tmp"
        temporary.write_text(json.dumps({"sequence": sequence, "action": action}))
        temporary.replace(output / "fullscreen-command.json")
        wait(lambda: report().get("outcomes", {}).get("video_command") == f"{sequence}:issued")

    try:
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True)
        bootstrapped = True
        with (output / "browser.log").open("x") as log:
            browser = subprocess.Popen([
                str(app / "Contents/MacOS/Chromium"), "--user-data-dir=" + str(output / "profile"),
                "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
                "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
                "--force-renderer-accessibility", "--winmux-sidebar-preview",
                "--winmux-test-service=" + service,
                "--winmux-bridge-report=" + str(output / "bridge.json"), "about:blank",
            ], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        wait(lambda: report().get("outcomes", {}).get("video_fullscreen") == "ready", timeout=45)
        for layout in ("standalone", "stack", "split", "release", "standalone"):
            control(layout)
            control("focus")
            time.sleep(.5)
            mode = "released" if layout == "release" else "managed"
            attempt = subprocess.run([str(probe), str(browser.pid), mode],
                                     capture_output=True, text=True, timeout=30)
            result["cases"].append({"layout": layout, "exit_code": attempt.returncode,
                                    "stdout": attempt.stdout, "stderr": attempt.stderr})
            assert attempt.returncode == 0, result["cases"][-1]
            assert browser.poll() is None, "Browser exited after menu interaction"
            print(f"{layout}: page menu passed", flush=True)
        result["passed"] = True
    except Exception as error:
        result["error"] = str(error)
    finally:
        if browser and browser.poll() is None:
            browser.terminate()
            try:
                browser.wait(timeout=15)
            except subprocess.TimeoutExpired:
                browser.kill()
                browser.wait(timeout=10)
        if browser:
            result["browser_exit_code"] = browser.returncode
            result["passed"] = result["passed"] and browser.returncode == 0
        if bootstrapped:
            clean = subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{service}"], capture_output=True)
            result["test_service_removed"] = clean.returncode == 0
            result["passed"] = result["passed"] and clean.returncode == 0
        server.shutdown()
        server.server_close()
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
