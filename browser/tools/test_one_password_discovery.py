#!/usr/bin/env python3
"""Probe native-host discovery with a disposable extension that 1Password rejects.

Reads only 1Password's public native-host registration. Never loads the real
extension, sends it messages, opens a vault, or changes a trusted-browser entry.
Uses an unregistered test XPC service and fresh profiles to protect live WinMux.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

from measure_helper import Sampler


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(sampler):
    value = sampler.read()
    return {k: value[k] for k in ("process_start_ticks", "executable_uuid")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--existing-helper-pid", type=int, required=True)
    parser.add_argument("--existing-helper-executable", type=Path, required=True)
    parser.add_argument("--expect-missing", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    manifest_path = app.parent / "winmux-package-manifest.json"
    package = json.loads(manifest_path.read_text())
    executable = app / "Contents/MacOS/Chromium"
    assert package["verified"] and digest(executable) == package["browser_executable_sha256"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    sampler = Sampler(args.existing_helper_pid, args.existing_helper_executable)
    before = identity(sampler)
    host = "com.1password.1password"
    support = Path.home() / "Library/Application Support"
    candidates = [support / product / "NativeMessagingHosts" / (host + ".json")
                  for product in ("Google/Chrome", "Chromium")]
    registration = next(path for path in candidates if path.is_file())
    installed = json.loads(registration.read_text())
    assert installed["name"] == host and installed["type"] == "stdio"
    registration_hash = digest(registration)
    # An independent test key ensures this fixture can never use 1Password's
    # extension identity. Generate it locally; no real account/extension data.
    private_key = output / "fixture-key.pem"
    subprocess.run(["openssl", "genrsa", "-out", str(private_key), "2048"],
                   check=True, capture_output=True)
    public_key = subprocess.check_output(["openssl", "rsa", "-in", str(private_key),
                                         "-pubout", "-outform", "DER"], stderr=subprocess.DEVNULL)
    extension_id = "".join(chr(ord("a") + int(x, 16)) for x in hashlib.sha256(public_key).hexdigest()[:32])
    assert "chrome-extension://" + extension_id + "/" not in installed["allowed_origins"]
    observations = []
    nonce = uuid.uuid4().hex

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            if self.path != "/" + nonce:
                self.send_error(404)
                return
            data = json.loads(self.rfile.read(min(int(self.headers["Content-Length"]), 2048)))
            observations.append(data)
            self.send_response(200)
            self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f"http://127.0.0.1:{server.server_port}/{nonce}"
    extension = output / "extension"
    extension.mkdir()
    (extension / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "WinMux native messaging discovery fixture",
        "version": "1.0", "key": base64.b64encode(public_key).decode(),
        "permissions": ["nativeMessaging"], "host_permissions": ["http://127.0.0.1/*"],
        "background": {"service_worker": "worker.js"},
    }))
    (extension / "worker.js").write_text("""
const port = chrome.runtime.connectNative('com.1password.1password');
port.onDisconnect.addListener(() => {
  const error = chrome.runtime.lastError?.message || '';
  fetch(ENDPOINT, {method: 'POST', body: JSON.stringify({id: chrome.runtime.id, error})});
});
// Send no message and record no response from the native host.
""".replace("ENDPOINT", json.dumps(endpoint)))
    profile = output / "profile"
    service = "com.jameslyons.winmux.browser.alpha.workspace.test." + str(uuid.uuid4())
    command = [str(executable), "--headless=new", "--user-data-dir=" + str(profile),
               "--no-first-run", "--no-default-browser-check",
               "--disable-extensions-except=" + str(extension), "--load-extension=" + str(extension),
               "--winmux-test-service=" + service,
               "--winmux-bridge-report=" + str(output / "bridge.json"), "about:blank"]
    result = {"passed": False, "scope": "signed_browser_host_discovery_and_origin_rejection",
              "desktop_unlock_verified": False, "package_manifest_sha256": digest(manifest_path),
              "test_source_sha256": digest(Path(__file__)), "expected_missing": args.expect_missing,
              "command": command, "registration_sha256": registration_hash}
    process = None
    try:
        with (output / "browser.log").open("x") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 40
            while not observations and time.monotonic() < deadline:
                assert process.poll() is None, "Test browser exited early"
                time.sleep(.1)
            assert observations, "Extension did not report a native-host result"
            expected = ("Specified native messaging host not found." if args.expect_missing else
                        "Access to the specified native messaging host is forbidden.")
            assert observations == [{"id": extension_id, "error": expected}], observations
            assert not (profile / "NativeMessagingHosts" / (host + ".json")).exists()
            result["observations"] = observations
            result["passed"] = True
    except Exception as error:
        result["error"] = str(error)
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        server.shutdown()
        server.server_close()
        result["browser_exit_code"] = process.returncode if process else None
        result["existing_helper_unchanged"] = identity(sampler) == before
        result["registration_unchanged"] = digest(registration) == registration_hash
        result["passed"] = (result["passed"] and result["existing_helper_unchanged"] and
                            result["registration_unchanged"] and result["browser_exit_code"] == 0)
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result.get(k) for k in ("passed", "error", "observations", "existing_helper_unchanged")}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
