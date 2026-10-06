#!/usr/bin/env python3
"""Exercise filter updates in a signed browser against an isolated TLS fixture.

Uses fresh profiles and a UUID test-service name. Only the two fixed EasyList
URLs resolve, to loopback; the fixture certificate is trusted by its public-key
hash for this process only. Installed browsers and system trust are untouched.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading
import time
import uuid

from test_browser_layout_watchdog import stop_process

LIMIT = 5 * 1024 * 1024
PATHS = ("/easylist/easylist.txt", "/easylist/easyprivacy.txt")


def rules(label, size=2048):
    prefix = b"[Adblock Plus 2.0]\n! "
    suffix = ("\n||" + label + ".winmux-filter.test^$script\n").encode()
    # Keep comment lines below the blocker's per-line validation limit so a
    # maximum-sized fixture exercises the download bound, not malformed rules.
    count = size - len(prefix) - len(suffix)
    line = b"x" * 1020 + b"\n! "
    body = prefix + line * (count // len(line)) + line[:count % len(line)] + suffix
    assert len(body) == size and max(map(len, body.splitlines())) <= 16 * 1024
    return body


def certificate(output):
    key, cert = output / "fixture.key", output / "fixture.crt"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(key), "-out", str(cert), "-days", "2",
                    "-subj", "/CN=easylist.to"], check=True, capture_output=True)
    key.chmod(0o600)
    public = subprocess.check_output(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
    der = subprocess.check_output(["openssl", "pkey", "-pubin", "-outform", "DER"], input=public)
    return key, cert, base64.b64encode(hashlib.sha256(der).digest()).decode()


def run_case(binary, output, name, tls, expect_crash):
    output.mkdir()
    profile = output / "profile"
    profile.mkdir(mode=0o700)
    permitted = name != "disabled"
    (profile / "winmux-services.json").write_text(json.dumps({
        "version": 1, "security_updates": False, "extension_updates": False,
        "filter_updates": permitted,
    }))
    bodies = [rules("first"), rules("second")]
    if name == "at_limit":
        bodies = [rules("first", LIMIT), rules("second", LIMIT)]
    if name == "oversized_first":
        bodies[0] = rules("first", LIMIT + 1)
    if name == "oversized_second":
        bodies[1] = rules("second", LIMIT + 1)
    if name == "malformed_second":
        bodies[1] = b"<!doctype html>" + b"x" * 2048
    cache = profile / "winmux-filters.txt"
    seeded = name not in ("fresh", "disabled", "at_limit")
    seed = rules("previous")
    if seeded:
        cache.write_bytes(seed)
        modified = time.time() if name == "recent_cache" else time.time() - 2 * 86400
        os.utime(cache, (modified, modified))
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            entry = {"path": self.path, "cookie_present": "Cookie" in self.headers,
                     "authorization_present": "Authorization" in self.headers}
            requests.append(entry)
            if self.path not in PATHS:
                self.send_error(404)
                return
            code = 503 if name == "http_error" else 200
            payload = bodies[PATHS.index(self.path)]
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
                self.wfile.flush()
                entry["response_sent"] = True
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                entry["response_interrupted"] = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(tls[1]), str(tls[0]))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    expected_paths = ([] if name in ("disabled", "recent_cache") else
                      list(PATHS[:1] if name in ("oversized_first", "http_error") else PATHS))
    successful = name in ("fresh", "at_limit")
    expected_cache = bodies[0] + b"\n" + bodies[1] + b"\n" if successful else seed if seeded else None
    command = [str(binary), "--user-data-dir=" + str(profile), "--headless=new",
               "--no-first-run", "--no-default-browser-check", "--enable-logging=stderr",
               "--no-proxy-server", "--ignore-certificate-errors-spki-list=" + tls[2],
               "--host-resolver-rules=MAP easylist.to 127.0.0.1:" + str(server.server_port) + ", MAP * ~NOTFOUND",
               "--winmux-test-service=com.jameslyons.winmux.browser.alpha.workspace.test." + str(uuid.uuid4()),
               "about:blank"]
    result = {"case": name, "passed": False, "requests": requests}
    browser = None
    started = time.monotonic()
    try:
        with (output / "browser.log").open("x") as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = started + 40
        ready_since = None
        while time.monotonic() < deadline:
            if browser.poll() is not None:
                text = (output / "browser.log").read_text(errors="replace")
                if expect_crash and browser.returncode != 0 and "max_body_size <= kMaxBoundedStringDownloadSize" in text:
                    result.update(passed=True, expected_rc2_crash=True, crash_exit_code=browser.returncode)
                    break
                raise RuntimeError(f"Browser exited unexpectedly: {browser.returncode}")
            if expect_crash:
                time.sleep(.05)
                continue
            actual_cache = cache.read_bytes() if cache.exists() else None
            observed_paths = [entry["path"] for entry in requests]
            if actual_cache == expected_cache and observed_paths == expected_paths:
                if ready_since is None:
                    ready_since = time.monotonic()
                if time.monotonic() - ready_since >= 8:
                    result.update(passed=True, cache_bytes=len(actual_cache) if actual_cache else 0,
                                  cache_sha256=hashlib.sha256(actual_cache).hexdigest() if actual_cache else None,
                                  stable_after_expected_result_seconds=time.monotonic() - ready_since,
                                  prior_cache_preserved=seeded and actual_cache == seed)
                    break
            else:
                ready_since = None
            time.sleep(.05)
        if not result["passed"]:
            raise TimeoutError("Expected crash or filter-update result was not observed")
        if any(x["cookie_present"] or x["authorization_present"] for x in requests):
            raise RuntimeError("Filter requests carried credentials")
    except (Exception, KeyboardInterrupt) as error:
        result.update(passed=False, error=f"{type(error).__name__}: {error}")
    finally:
        result["elapsed_seconds"] = time.monotonic() - started
        result["browser_cleanup"] = stop_process(browser)
        result["browser_exit_code"] = browser.returncode if browser else None
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        result["server_cleanup"] = not thread.is_alive()
        if not expect_crash:
            result["passed"] &= result["browser_exit_code"] == 0
        result["passed"] &= result["browser_cleanup"] and result["server_cleanup"]
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expect-rc2-crash", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    manifest_path = app.parent / "winmux-package-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    binary = app / "Contents/MacOS/Chromium"
    assert manifest["verified"] is True
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest["browser_executable_sha256"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    tls = certificate(output)
    names = ["fresh"] if args.expect_rc2_crash else [
        "fresh", "at_limit", "oversized_first", "oversized_second",
        "malformed_second", "http_error", "disabled", "recent_cache",
    ]
    cases = []
    for name in names:
        result = run_case(binary, output / name, name, tls, args.expect_rc2_crash)
        cases.append(result)
        print(json.dumps(result), flush=True)
        if not result["passed"]:
            break
    report = {"passed": len(cases) == len(names) and all(x["passed"] for x in cases),
              "expected_rc2_crash": args.expect_rc2_crash,
              "package_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
              "fixture_source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "cases": cases, "scope": "Isolated headless browser, fresh profiles, loopback TLS responses; no installed workspace changes."}
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
