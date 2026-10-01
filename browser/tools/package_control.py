#!/usr/bin/env python3
"""Sign a copy of the preserved upstream control for matched browser measurements.

Never rebuilds or modifies the control archive. Uses the same upstream signing
policy and Personal Team identity as the alpha, with separate control identities.
"""
import argparse
import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys
from types import SimpleNamespace

import build_alpha
import chromium
from package_alpha import DevelopmentSigner, sha256, verify_identity

APP_NAME = "WinMux Browser Control"
APP_ID = "com.jameslyons.winmux.browser.control"


def validate_control(manifest, build):
    if manifest.get("configuration") != "browser-only-control" or manifest.get("build_succeeded") is False:
        raise RuntimeError("The preserved upstream control is required")
    if manifest.get("pins", {}).get("chromium", {}).get("revision") != chromium.PINS["chromium"]["revision"]:
        raise RuntimeError("Control revision differs from the pin")
    if manifest.get("pins", {}).get("depot_tools", {}).get("revision") != chromium.PINS["depot_tools"]["revision"]:
        raise RuntimeError("Control tool revision differs from the pin")
    if manifest.get("args_sha256") != sha256(chromium.CONFIG / "args.gn"):
        raise RuntimeError("Control configuration differs from the alpha")
    if sha256(build / "args.gn") != manifest["args_sha256"]:
        raise RuntimeError("Control build arguments have changed")
    app = build / "Chromium.app"
    if (app / "Contents/Helpers/WinMuxWorkspaceHelper").exists() or (
            app / "Contents/Helpers/WinMux Workspace.app").exists() or (
            app / "Contents/Frameworks/Chromium Framework.framework/Libraries/libwinmux_blocking.dylib").exists():
        raise RuntimeError("Control contains downstream components")


def validate_output(output, build):
    # Resolve parent symlinks before any mkdir/copy/signing operation. A staging
    # directory inside the archive would violate the immutable-control contract.
    output = output.expanduser().resolve()
    if output.is_relative_to(build.resolve()):
        raise RuntimeError("Package output must be outside the preserved control")
    if output.exists():
        raise RuntimeError("Refusing to overwrite an existing package directory")
    return output


def package(engine, output, identity, team):
    build = engine / "chromium/src/out/WinMuxControlBaseline"
    output = validate_output(output, build)
    manifest_path = build / "winmux-build-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    validate_control(manifest, build)
    raw_app = build / "Chromium.app"
    raw_files = [raw_app / "Contents/MacOS/Chromium",
                 raw_app / "Contents/Frameworks/Chromium Framework.framework/Chromium Framework",
                 manifest_path]
    hashes = {str(p.relative_to(build)): sha256(p) for p in raw_files}
    packaging = build / "Chromium Packaging"
    sys.path.insert(0, str(packaging))
    from signing import model, parts
    from signing.chromium_config import ChromiumCodeSignConfig

    class ControlConfig(ChromiumCodeSignConfig):
        @property
        def app_product(self):
            return APP_NAME

        @property
        def base_bundle_id(self):
            return APP_ID

        @property
        def run_spctl_assess(self):
            return False

    config = ControlConfig(identity=identity, invoker=SimpleNamespace(signer=DevelopmentSigner()),
                           notarize=model.NotarizeAndStapleLevel.NONE)
    output.mkdir(parents=True)
    report_path = output / "winmux-package-manifest.json"
    report = {"scope": "private_development_upstream_control", "verified": False,
              "notarized": False, "identity_sha1": identity, "team_identifier": team,
              "created_utc": datetime.now(timezone.utc).isoformat(), "build": manifest,
              "raw_control_sha256": hashes, "package_tool_sha256": sha256(Path(__file__))}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    app = output / (APP_NAME + ".app")
    chromium.run("cp", "-cpR", str(raw_app), str(app))
    for part in parts.get_parts(config).values():
        path = output / part.path
        info = path / ("Contents/Info.plist" if path.suffix == ".app" else "Resources/Info.plist")
        if not info.is_file():
            continue
        data = plistlib.loads(info.read_bytes())
        data["CFBundleIdentifier"] = part.identifier
        if part.identifier == APP_ID:
            data.update(CFBundleDisplayName=APP_NAME, CFBundleName=APP_NAME, CrProductDirName=APP_NAME)
            for scheme in data.get("CFBundleURLTypes", []):
                name = scheme.get("CFBundleURLName", "")
                if name.startswith("org.chromium.Chromium"):
                    scheme["CFBundleURLName"] = name.replace("org.chromium.Chromium", APP_ID, 1)
        info.write_bytes(plistlib.dumps(data))
        if part.entitlements:
            shutil.copy2(packaging / part.entitlements, output / part.entitlements)
    paths = model.Paths(input=str(build), output=str(output), work=str(output))
    asyncio.run(parts.sign_chrome(paths, config, sign_framework=True))
    verify_identity(app, APP_ID, team)
    if {str(p.relative_to(build)): sha256(p) for p in raw_files} != hashes:
        raise RuntimeError("Preserved control changed during packaging")
    report.update(verified=True, app=str(app), preserved_control_unchanged=True,
                  browser_executable_sha256=sha256(app / "Contents/MacOS/Chromium"),
                  framework_sha256=sha256(app / "Contents/Frameworks/Chromium Framework.framework/Chromium Framework"))
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"app": str(app), "verified": True, "preserved_control_unchanged": True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    identity = os.environ.get("BROWSER_SIGNING_IDENTITY", "")
    team = os.environ.get("BROWSER_SIGNING_TEAM", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("Source signing.env with the verified identity and team")
    engine = args.root.expanduser().resolve()
    with build_alpha.acquire_engine_lock(engine, exclusive=False):
        package(engine, args.output.expanduser().absolute(), identity, team)


if __name__ == "__main__":
    main()
