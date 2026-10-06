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
import tempfile
import uuid
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


def brand_application(app, name, icon):
    """Use one app identity in Finder, the Dock and localized macOS prompts."""
    resources = app / "Contents/Resources"
    info = app / "Contents/Info.plist"
    data = plistlib.loads(info.read_bytes())
    data.update(CFBundleDisplayName=name, CFBundleName=name, CFBundleIconFile="app.icns")
    info.write_bytes(plistlib.dumps(data))
    shutil.copy2(icon, resources / "app.icns")
    for localized in resources.glob("*.lproj/InfoPlist.strings"):
        try:
            strings = plistlib.loads(localized.read_bytes())
        except plistlib.InvalidFileException:
            # Chromium ships OpenStep .strings files, not just binary/XML
            # plists. Let macOS parse their escaping and localized text.
            strings = plistlib.loads(subprocess.check_output(
                ["plutil", "-convert", "binary1", "-o", "-", str(localized)]))
        strings.update(CFBundleDisplayName=name, CFBundleName=name)
        # Preserve upstream copyright/attribution and unrelated translations.
        for key, value in strings.items():
            if key.startswith("NS") and key.endswith("UsageDescription") and isinstance(value, str):
                strings[key] = value.replace("Chromium", name)
        localized.write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY))


def create_application_icon(source, directory):
    iconset = directory / "WinMux.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = str(size * scale)
            output = iconset / f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            chromium.run("sips", "-z", pixels, pixels, str(source), "--out", str(output))
    icon = directory / "WinMux.icns"
    chromium.run("iconutil", "--convert", "icns", "--output", str(icon), str(iconset))
    return icon


def validate_manifest(manifest, source):
    if manifest.get("configuration") != "alpha-milestone-0" or manifest.get("build_succeeded") is not True:
        raise RuntimeError("A successfully built alpha is required; raw control builds cannot be packaged")
    if manifest.get("chromium_revision") != chromium.PINS["chromium"]["revision"]:
        raise RuntimeError("Unexpected alpha Chromium revision")
    if manifest.get("args_sha256") != sha256(ROOT / "browser/chromium/args.gn"):
        raise RuntimeError("Alpha build configuration no longer matches")
    if manifest.get("patches_sha256") != {p.name: sha256(p) for p in build_alpha.integration_patches()}:
        raise RuntimeError("Alpha patch changed since compilation")
    hashes = manifest.get("overlay_sha256", {})
    if not hashes:
        raise RuntimeError("Missing alpha source provenance")
    for name, expected in hashes.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or not name.startswith(build_alpha.OWNED_PREFIXES):
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
    parser.add_argument("--views-trial", action="store_true", help="Package the tab-style trial with separate profile and state")
    args = parser.parse_args()
    identity = os.environ.get("BROWSER_SIGNING_IDENTITY", "")
    team = os.environ.get("BROWSER_SIGNING_TEAM", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", identity) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("Source signing.env with an exact certificate SHA-1 and Apple team identifier")
    engine = args.root.expanduser().resolve()
    with build_alpha.acquire_engine_lock(engine, exclusive=False):
        package(args, identity, team, engine / "chromium/src")


def package(args, identity, team, source):
    views_trial = args.views_trial
    app_name = "WinMux Browser Views Trial" if views_trial else APP_NAME
    build = source / "out/WinMuxControl"
    manifest = json.loads((build / "winmux-build-manifest.json").read_text())
    validate_manifest(manifest, source)
    if chromium.output("git", "rev-parse", "HEAD", cwd=source) != manifest["chromium_revision"]:
        raise RuntimeError("Engine checkout no longer matches the alpha build")
    patches = build_alpha.integration_patches()
    if build_alpha.owned_patch_prefix(source, patches) != len(patches):
        raise RuntimeError("Compiled alpha patch is no longer applied to the checkout")
    for name, expected in manifest.get("blocking", {}).get("source_sha256", {}).items():
        if sha256(ROOT / name) != expected:
            raise RuntimeError("Blocker source changed since compilation")
    if sha256(build / "libwinmux_blocking.dylib") != manifest.get("blocking", {}).get("library_sha256"):
        raise RuntimeError("Missing or changed blocker build artifact")
    # Import the generated upstream signing configuration for this exact build.
    packaging = build / "Chromium Packaging"
    sys.path.insert(0, str(packaging))
    from signing import model, parts
    from signing.chromium_config import ChromiumCodeSignConfig

    class AlphaConfig(ChromiumCodeSignConfig):
        @property
        def app_product(self):
            return app_name

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
    report = {"scope": "private_development_alpha_milestone_0", "verified": False,
              "notarized": False, "views_trial": views_trial, "identity_sha1": identity, "team_identifier": team,
              "build": manifest, "created_utc": datetime.now(timezone.utc).isoformat()}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    app = output / (app_name + ".app")
    chromium.run("cp", "-cpR", str(build / "Chromium.app"), str(app))
    blocker_library = app / "Contents/Frameworks/Chromium Framework.framework/Libraries/libwinmux_blocking.dylib"
    chromium.run("codesign", "--force", "--sign", identity, "--identifier", APP_ID + ".blocking",
                 "--timestamp=none", str(blocker_library))
    verify_identity(blocker_library, APP_ID + ".blocking", team)
    notices = app / "Contents/Resources/WinMuxBlocking"
    shutil.copytree(ROOT / "browser/blocking/resources", notices)
    native = ROOT / "browser/native"
    native_build = ROOT / ".local/browser/sidebar-native-build"
    chromium.run("swift", "build", "--package-path", str(ROOT), "-c", "release",
                 "--product", "WinMuxWorkspaceHelper", "--jobs", "4", "--scratch-path", str(native_build))
    helper_app = app / "Contents/Helpers/WinMux Workspace.app"
    helper_relative = "Contents/Helpers/WinMux Workspace.app/Contents/MacOS/WinMuxWorkspaceHelper"
    helper = app / helper_relative
    helper.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(native_build / "release/WinMuxWorkspaceHelper", helper)
    (helper_app / "Contents/Resources").mkdir()
    shutil.copy2(ROOT / "resources/default-config.toml", helper_app / "Contents/Resources/default-config.toml")
    validation_service = HELPER_ID + ".test." + str(uuid.uuid4())
    (helper_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": HELPER_ID, "CFBundleName": "WinMux Workspace",
        "CFBundleDisplayName": "WinMux Workspace", "CFBundleExecutable": helper.name,
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSUIElement": True,
        "NSHighResolutionCapable": True, "LSMinimumSystemVersion": "13.0",
        "WinMuxValidationService": validation_service,
        "WinMuxWorkspaceViewsTrial": views_trial,
    }))
    for resource in (native_build / "release").glob("*.bundle"):
        destination = helper_app / "Contents/Resources" / resource.name
        shutil.copytree(resource, destination)
        chromium.run("codesign", "--force", "--sign", identity,
                     "--identifier", HELPER_ID + ".resources." + resource.stem,
                     "--timestamp=none", str(destination))
    agents = app / "Contents/Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    agent = plistlib.loads((native / (HELPER_ID + ".plist")).read_bytes())
    agent["BundleProgram"] = helper_relative
    (agents / (HELPER_ID + ".plist")).write_bytes(plistlib.dumps(agent))
    # Workspace Setup runs inside the embedded helper application. Its separate
    # SMAppService agent does not replace the browser's transport-only enrollment.
    managed_agents = helper_app / "Contents/Library/LaunchAgents"
    managed_agents.mkdir(parents=True)
    managed_id = HELPER_ID + ".managed"
    (managed_agents / (managed_id + ".plist")).write_bytes(plistlib.dumps({
        "Label": managed_id, "BundleProgram": "Contents/MacOS/WinMuxWorkspaceHelper",
        "ProgramArguments": ["WinMuxWorkspaceHelper", "--managed-workspace"],
        "MachServices": {managed_id: True}, "ProcessType": "Interactive", "RunAtLoad": True,
    }))
    (managed_agents / (validation_service + ".plist")).write_bytes(plistlib.dumps({
        "Label": validation_service, "BundleProgram": "Contents/MacOS/WinMuxWorkspaceHelper",
        "ProgramArguments": ["WinMuxWorkspaceHelper", "--managed-workspace", validation_service],
        "MachServices": {validation_service: True}, "ProcessType": "Interactive", "RunAtLoad": True,
    }))
    chromium.run("codesign", "--force", "--sign", identity, "--identifier", HELPER_ID,
                 "--options", "runtime", "--timestamp=none", str(helper_app))
    verify_identity(helper, HELPER_ID, team)
    for part in parts.get_parts(config).values():
        part_path = output / part.path
        info = part_path / ("Contents/Info.plist" if part_path.suffix == ".app" else "Resources/Info.plist")
        if not info.is_file():
            continue
        data = plistlib.loads(info.read_bytes())
        data["CFBundleIdentifier"] = part.identifier
        if part.identifier == APP_ID:
            data.update(CFBundleDisplayName=app_name, CFBundleName=app_name,
                        CrProductDirName=app_name + " Launcher" if views_trial else app_name,
                        WinMuxWorkspaceViewsTrial=views_trial)
            for scheme in data.get("CFBundleURLTypes", []):
                name = scheme.get("CFBundleURLName", "")
                if name.startswith("org.chromium.Chromium"):
                    scheme["CFBundleURLName"] = name.replace("org.chromium.Chromium", APP_ID, 1)
        info.write_bytes(plistlib.dumps(data))
        if part.entitlements:
            shutil.copy2(packaging / part.entitlements, output / part.entitlements)
    icon_source = ROOT / "resources/Assets.xcassets/AppIcon.appiconset/icon.png"
    with tempfile.TemporaryDirectory(prefix="winmux-app-icon-") as icon_directory:
        icon = create_application_icon(icon_source, Path(icon_directory))
        brand_application(app, app_name, icon)
    paths = model.Paths(input=str(build), output=str(output), work=str(output))
    asyncio.run(parts.sign_chrome(paths, config, sign_framework=True))
    verify_identity(app, APP_ID, team)
    verify_identity(helper, HELPER_ID, team)
    report.update(verified=True, app=str(app), helper_sha256=sha256(helper), helper_relative_path=helper_relative,
                  browser_executable_sha256=sha256(app / "Contents/MacOS/Chromium"),
                  native_sources_sha256={str(p.relative_to(ROOT)): sha256(p)
                    for p in sorted(set(native.rglob("*.swift")) | set((ROOT / "Sources/AppBundle").rglob("*.swift"))
                                    | set((ROOT / "Sources/Common").rglob("*.swift")))},
                  native_package_sha256=sha256(ROOT / "Package.swift"),
                  default_config_sha256=sha256(ROOT / "resources/default-config.toml"),
                  package_tool_sha256=sha256(Path(__file__)),
                  app_icon_source_sha256=sha256(icon_source),
                  app_icon_sha256=sha256(app / "Contents/Resources/app.icns"))
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"app": str(app), "verified": True, "notarized": False}, indent=2))


if __name__ == "__main__":
    main()
