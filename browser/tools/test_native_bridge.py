#!/usr/bin/env python3
"""Build/sign and exercise actual async Objective-C++ ↔ Swift XPC processes.

Uses a temporary per-user LaunchAgent, removed in finally. Does not register an
SMAppService, install an app, open any profiles, or request Accessibility.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import hashlib
import signal
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "browser/native"
BUILD = ROOT / ".local/browser/native-build"
SERVICE = "com.jameslyons.winmux.browser.alpha.workspace"
CLIENT = "com.jameslyons.winmux.browser.alpha"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def sign(path, identifier, identity):
    run("codesign", "--force", "--sign", identity, "--identifier", identifier,
        "--options", "runtime", "--timestamp=none", str(path))
    run("codesign", "--verify", "--strict", str(path))


def main():
    def terminate(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    domain = f"gui/{os.getuid()}"
    target = domain + "/" + SERVICE
    if subprocess.run(["launchctl", "print", target], capture_output=True).returncode == 0:
        raise SystemExit("An alpha helper is already registered. Refusing to replace it for a test.")
    identity = os.environ.get("BROWSER_SIGNING_IDENTITY", "Apple Development")
    run("swift", "test", "--package-path", str(NATIVE), "-c", "release", "--scratch-path", str(BUILD))
    root = ROOT / ".local/browser"
    root.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="bridge-proof-", dir=root) as directory:
        directory = Path(directory)
        helper = directory / "WinMuxWorkspaceHelper"
        probe = directory / "bridge-probe"
        shutil.copy2(BUILD / "release/WinMuxWorkspaceHelper", helper)
        run("xcrun", "clang++", "-std=c++20", "-O2", "-fobjc-arc", "-framework", "Foundation",
            "-framework", "Security", "-I", str(NATIVE / "Sources/BridgeProtocol/include"),
            str(NATIVE / "probe/bridge_probe.mm"), "-o", str(probe))
        sign(helper, SERVICE, identity)
        sign(probe, CLIENT, identity)
        wrong = directory / "wrong-identity-probe"
        shutil.copy2(probe, wrong)
        sign(wrong, CLIENT + ".untrusted", identity)
        adhoc = directory / "adhoc-probe"
        shutil.copy2(probe, adhoc)
        sign(adhoc, CLIENT, "-")
        agent = directory / (SERVICE + ".plist")
        agent.write_bytes(plistlib.dumps({
            "Label": SERVICE, "ProgramArguments": [str(helper)],
            "MachServices": {SERVICE: True}, "RunAtLoad": True,
            "StandardErrorPath": str(directory / "helper.stderr"),
        }))
        registered = False
        try:
            run("launchctl", "bootstrap", domain, str(agent))
            registered = True
            run(str(probe), timeout=15)
            results.append("signed_client_and_helper_exchange")
            run(str(wrong), "--expect-rejection", timeout=15)
            results.append("same_team_wrong_identifier_rejected")
            # The ad-hoc client cannot derive a signing team, so it fails closed
            # before connecting. The wrong-ID case above reaches XPC enforcement.
            rejected = subprocess.run([str(adhoc)], timeout=15)
            if rejected.returncode != 2:
                raise RuntimeError("Ad-hoc client did not fail closed")
            results.append("adhoc_client_fails_closed")
            run(str(probe), timeout=15)
            results.append("healthy_client_after_rejected_client")
            run("launchctl", "bootout", target)
            registered = False
            sign(helper, SERVICE + ".impostor", identity)
            run("launchctl", "bootstrap", domain, str(agent))
            registered = True
            run(str(probe), "--expect-rejection", timeout=15)
            results.append("client_rejects_wrong_helper_identifier")
        finally:
            if registered:
                run("launchctl", "bootout", target)
        report = {"scope": "signed_xpc_transport_only", "presentation_measured": False,
                  "smappservice_packaging_verified": False, "passed": results,
                  "recorded_utc": datetime.now(timezone.utc).isoformat(),
                  "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in sorted((NATIVE / "Sources").rglob("*.swift"))
                        + [NATIVE / "probe/bridge_probe.mm", NATIVE / "Sources/BridgeProtocol/include/WMBridgeProtocol.h"]}}
        (root / "native-bridge-proof.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
