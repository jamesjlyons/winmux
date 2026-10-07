#!/usr/bin/env python3
"""Verify MP4 and Media Source H.264/AAC decoding in an actual browser package.

Uses Chromium's pinned media test clips, a loopback server, a fresh profile and
an isolated bridge service. No existing browser session or profile is changed.
WebM playback is checked as a control. A successful codec query alone cannot pass.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import threading
import time
import uuid

from test_browser_layout_watchdog import stop_process

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ("bear-1280x720.mp4", "bear-1280x720-av_frag.mp4", "bear-vp9-opus.webm")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--chromium-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New diagnostic directory")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    source = args.chromium_source.resolve(strict=True)
    pins = json.loads((ROOT / "browser/chromium/pins.json").read_text())
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != pins["chromium"]["revision"]:
        parser.error("Media fixtures must come from the pinned Chromium revision")
    if not executable.is_file():
        parser.error("Missing browser executable")
    payloads = {"/" + name: (source / "media/test/data" / name).read_bytes() for name in FIXTURES}
    fixture_hashes = {name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()}
    for name, data in payloads.items():
        original = subprocess.check_output(["git", "show", "HEAD:media/test/data" + name], cwd=source)
        if original != data:
            parser.error(f"Media fixture differs from the pinned source: {name}")
    payloads["/"] = (ROOT / "browser/tests/fixtures/media_playback.html").read_bytes()
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    received = threading.Event()
    report = {"passed": False, "app": str(app),
              "browser_version": info.get("CFBundleShortVersionString", info.get("CFBundleVersion")),
              "fixture_chromium_revision": revision,
              "fixtures_sha256": fixture_hashes}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            data = payloads.get(self.path)
            if data is None:
                self.send_error(404)
                return
            self.send_response(200)
            mime = "text/html; charset=utf-8" if self.path == "/" else (
                "video/webm" if self.path.endswith(".webm") else "video/mp4")
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.path != "/result":
                self.send_error(404)
                return
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size < 65536:
                self.send_error(400)
                return
            result = json.loads(self.rfile.read(size))
            report["media"] = result
            report["passed"] = result.get("passed") is True
            self.send_response(204)
            self.end_headers()
            received.set()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    command = [str(executable), "--headless=new", "--no-first-run", "--no-default-browser-check",
               "--profile-directory=Default", "--user-data-dir=" + str(output / "profile"),
               "--winmux-test-service=com.jameslyons.winmux.browser.alpha.workspace.test." + str(uuid.uuid4()),
               "--winmux-bridge-report=" + str(output / "bridge.json"),
               f"http://127.0.0.1:{server.server_port}/"]
    report["command"] = command
    browser = None
    try:
        with (output / "browser.log").open("x") as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 45
        while not received.wait(.1):
            if browser.poll() is not None:
                raise RuntimeError(f"Browser exited before media results: {browser.returncode}")
            if time.monotonic() >= deadline:
                raise TimeoutError("Browser did not report media results; inspect browser.log")
    except (Exception, KeyboardInterrupt) as error:
        report.update(passed=False, error=f"{type(error).__name__}: {error}")
    finally:
        report["browser_cleanup"] = stop_process(browser)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
