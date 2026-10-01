#!/usr/bin/env python3
"""Package a private development alpha using Chromium's per-process signing policy.

Creates a new staging directory; never installs over an application or changes
profiles. The Personal Team build is not notarized or a distributable release.
"""
import argparse
import asyncio
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from types import SimpleNamespace

import chromium
import build_alpha

ROOT = chromium.ROOT
APP_NAME = "WinMux Browser Alpha"
APP_ID = "com.jameslyons.winmux.browser.alpha"
HELPER_ID = APP_ID + ".workspace"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def signing_requirement(identifier, team):
    return f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'


def verify_identity(path, identifier, team):
    chromium.run("codesign", "--verify", "--strict", "-R",
                 "=" + signing_requirement(identifier, team), str(path))


def validate_manifest(manifest, source):
    if manifest.get("configuration") != "alpha-transport-proof" or manifest.get("build_succeeded") is not True:
        raise RuntimeError("A successfully built alpha is required; raw control builds cannot be packaged")
    if manifest.get("chromium_revision") != chromium.PINS["chromium"]["revision"]:
        raise RuntimeError("Unexpected alpha Chromium revision")
    if manifest.get("args_sha256") != sha256(ROOT / "browser/chromium/args.gn"):
        raise RuntimeError("Alpha build configuration no longer matches")
    if manifest.get("patch_sha256") != sha256(ROOT / "browser/chromium/patches/0001-workspace-bridge.patch"):
        raise RuntimeError("Alpha patch changed since compilation")
    hashes = manifest.get("overlay_sha256", {})
    if not hashes:
        raise RuntimeError("Missing alpha source provenance")
    for name, expected in hashes.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or relative.parts[:3] != ("chrome", "browser", "winmux"):
            raise RuntimeError("Unexpected overlay path")
        if sha256(source / relative) != expected:
            raise RuntimeError(f"Alpha source changed since compilation: {name}")


class DevelopmentSigner:
    """Use upstream part policy, replacing the linker-generated ad-hoc signatures."""
    def codesign(self, config, product, path):
        command = ["codesign", "--force", "--sign", config.identity, "--timestamp=none"]
        if product.sign_with_identifier:
            command += ["--identifier", product.identifier]
        requirement = product.requirements_string(config)
        if requirement:
            command += ["--requirements", "=" + requirement]
        if product.options:
            command += ["--options", product.options.to_comma_delimited_string()]
        if product.entitlements:
            command += ["--entitlements", str(Path(path) / product.entitlements)]
        chromium.run(*command, str(Path(path) / product.path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New package directory (must not exist)")
    args = parser.parse_args()
    identity = os.environ.get("BROWSER_SIGNING_IDENTITY", "")
    team = os.environ.get("BROWSER_SIGNING_TEAM", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("Source signing.env with an exact certificate SHA-1 and Apple team identifier")
    engine = args.root.expanduser().resolve()
    with build_alpha.acquire_engine_lock(engine, exclusive=False):
        package(args, identity, team, engine / "chromium/src")


def package(args, identity, team, source):
    build = source / "out/WinMuxControl"
    manifest = json.loads((build / "winmux-build-manifest.json").read_text())
    validate_manifest(manifest, source)
    if chromium.output("git", "rev-parse", "HEAD", cwd=source) != manifest["chromium_revision"]:
        raise RuntimeError("Engine checkout no longer matches the alpha build")
    if not build_alpha.owned_patch_state(source, (ROOT / "browser/chromium/patches/0001-workspace-bridge.patch").read_bytes()):
        raise RuntimeError("Compiled alpha patch is no longer applied to the checkout")
    # Import the generated upstream signing configuration for this exact build.
    packaging = build / "Chromium Packaging"
    sys.path.insert(0, str(packaging))
    from signing import model, parts
    from signing.chromium_config import ChromiumCodeSignConfig

    class AlphaConfig(ChromiumCodeSignConfig):
        @property
        def app_product(self):
            return APP_NAME

        @property
        def base_bundle_id(self):
            return APP_ID

        @property
        def run_spctl_assess(self):
            # Personal Team development signing does not imply notarization.
            return False

    config = AlphaConfig(identity=identity, invoker=SimpleNamespace(signer=DevelopmentSigner()),
                         notarize=model.NotarizeAndStapleLevel.NONE)
    output = args.output.expanduser().absolute()
    if output.exists():
        raise RuntimeError("Refusing to overwrite an existing package directory")
    output.mkdir(parents=True)
    report_path = output / "winmux-package-manifest.json"
    report = {"scope": "private_development_alpha_transport_proof", "verified": False,
              "notarized": False, "identity_sha1": identity, "team_identifier": team,
              "build": manifest, "created_utc": datetime.now(timezone.utc).isoformat()}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    app = output / (APP_NAME + ".app")
    chromium.run("cp", "-cpR", str(build / "Chromium.app"), str(app))
    native = ROOT / "browser/native"
    native_build = ROOT / ".local/browser/native-build"
    chromium.run("swift", "build", "--package-path", str(native), "-c", "release",
                 "--scratch-path", str(native_build))
    helper = app / "Contents/Helpers/WinMuxWorkspaceHelper"
    helper.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(native_build / "release/WinMuxWorkspaceHelper", helper)
    agents = app / "Contents/Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    shutil.copy2(native / (HELPER_ID + ".plist"), agents)
    chromium.run("codesign", "--force", "--sign", identity, "--identifier", HELPER_ID,
                 "--options", "runtime", "--timestamp=none", str(helper))
    verify_identity(helper, HELPER_ID, team)
    for part in parts.get_parts(config).values():
        part_path = output / part.path
        info = part_path / ("Contents/Info.plist" if part_path.suffix == ".app" else "Resources/Info.plist")
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
    verify_identity(helper, HELPER_ID, team)
    report.update(verified=True, app=str(app), helper_sha256=sha256(helper),
                  browser_executable_sha256=sha256(app / "Contents/MacOS/Chromium"),
                  native_sources_sha256={str(p.relative_to(ROOT)): sha256(p)
                    for p in sorted(native.rglob("*.swift"))},
                  package_tool_sha256=sha256(Path(__file__)))
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"app": str(app), "verified": True, "notarized": False}, indent=2))


if __name__ == "__main__":
    main()
