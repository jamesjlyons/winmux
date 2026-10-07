"""Freeze and verify the already signed glass + codec package for local delivery."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
REQUEST_PATH = ROOT / "artifacts/liquid-glass-refresh/package-request.json"
request = json.loads(REQUEST_PATH.read_text())
OUTPUT = Path(request["output_directory"])
SOURCE_MANIFEST = ROOT / ".local/media-playback/package/winmux-package-manifest.json"
manifest_bytes = SOURCE_MANIFEST.read_bytes()
package = json.loads(manifest_bytes)
SOURCE_APP = Path(package["app"])
APP_NAME = SOURCE_APP.name
ENGINE = Path(request["engine_root"])


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def run(*command):
    subprocess.run([str(value) for value in command], check=True, cwd=ROOT)


def inventory(app):
    result = {}
    for path in sorted(app.rglob("*")):
        info = path.lstat()
        key = str(path.relative_to(app))
        item = {"mode": stat.S_IMODE(info.st_mode)}
        if path.is_symlink():
            item.update(type="symlink", target=os.readlink(path))
        elif path.is_dir():
            item.update(type="directory")
        elif path.is_file():
            item.update(type="file", sha256=sha(path), bytes=info.st_size)
        else:
            raise RuntimeError("Unexpected bundle entry: " + key)
        result[key] = item
    return result


sys.path.insert(0, str(ROOT / "browser/tools"))
import build_alpha
import package_alpha

assert package["verified"] is True
assert not OUTPUT.exists(), "Refusing to overwrite a release"
assert package["build"]["args_sha256"] == request["expected_gn_args_sha256"]
assert sha(ROOT / "browser/chromium/args.gn") == request["expected_gn_args_sha256"]
for source, expected in request["ui_sources_sha256"].items():
    assert package["native_sources_sha256"].get(source) == expected, source
for source, expected in package["native_sources_sha256"].items():
    assert sha(ROOT / source) == expected, source
assert sha(SOURCE_APP / package["helper_relative_path"]) == package["helper_sha256"]
assert sha(SOURCE_APP / "Contents/MacOS/Chromium") == package["browser_executable_sha256"]

with build_alpha.acquire_engine_lock(ENGINE, exclusive=False):
    build = json.loads((ENGINE / "chromium/src/out/WinMuxControl/winmux-build-manifest.json").read_text())
    assert package["build"] == build
    package_alpha.validate_manifest(build, ENGINE / "chromium/src")
    print("Freezing signed package with all requested UI source hashes.", flush=True)
    OUTPUT.mkdir(parents=True)
    app = OUTPUT / "staging" / APP_NAME
    app.parent.mkdir()
    run("ditto", SOURCE_APP, app)
    assert SOURCE_MANIFEST.read_bytes() == manifest_bytes
    assert sha(app / package["helper_relative_path"]) == package["helper_sha256"]
    assert sha(app / "Contents/MacOS/Chromium") == package["browser_executable_sha256"]

run("codesign", "--verify", "--deep", "--strict", app)
package_alpha.verify_identity(app, package_alpha.APP_ID, package["team_identifier"])
package_alpha.verify_identity(app / package["helper_relative_path"], package_alpha.HELPER_ID, package["team_identifier"])
baseline = inventory(SOURCE_APP)
assert inventory(app) == baseline, "Frozen copy differs from original signed app"
write_json(OUTPUT / "bundle-inventory.json", baseline)
(OUTPUT / "package-manifest.json").write_bytes(manifest_bytes)
shutil.copy2(REQUEST_PATH, OUTPUT / "package-request.json")
shutil.copy2(ROOT / "artifacts/liquid-glass-refresh/report.json", OUTPUT / "ui-verification.json")

print("Checking decoded video and audio in the frozen release app.", flush=True)
run(sys.executable, ROOT / "browser/tools/test_browser_media.py", "--app", app,
    "--chromium-source", ENGINE / "chromium/src", "--output", OUTPUT / "media-check")
media = json.loads((OUTPUT / "media-check/result.json").read_text())
assert media["passed"] and media["browser_cleanup"]
assert {test["name"] for test in media["media"]["playback"] if test["passed"] and test["frames"] > 0 and test["audioBytes"] > 0} == {
    "mp4_h264_aac", "mse_h264_aac", "webm_vp9_opus"}
assert inventory(app) == baseline, "Playback check changed the signed app"
shutil.copy2(OUTPUT / "media-check/result.json", OUTPUT / "media-verification.json")

print("Creating versioned ZIP and verifying its extracted contents.", flush=True)
archive = OUTPUT / "WinMux-Browser-Alpha-Glass-Video-2026-10-06-rc1-arm64.zip"
run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
extraction = OUTPUT / "verification"
extraction.mkdir()
run("ditto", "-x", "-k", archive, extraction)
extracted = extraction / APP_NAME
assert inventory(extracted) == baseline, "Archive round-trip changed content, links, or permissions"
run("codesign", "--verify", "--deep", "--strict", extracted)
package_alpha.verify_identity(extracted, package_alpha.APP_ID, package["team_identifier"])
package_alpha.verify_identity(extracted / package["helper_relative_path"], package_alpha.HELPER_ID, package["team_identifier"])
info = plistlib.loads((extracted / "Contents/Info.plist").read_bytes())
release = {
    "release": "browser-alpha-glass-video-2026-10-06-rc1",
    "created_utc": datetime.now(timezone.utc).isoformat(),
    "source_base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
    "source_package": str(SOURCE_APP),
    "source_package_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
    "binary_provenance": "Reused the signed codec-enabled package whose native source hashes match all requested UI changes and current native sources. No rebuild or re-signing during archive preparation.",
    "archive": archive.name,
    "archive_bytes": archive.stat().st_size,
    "archive_sha256": sha(archive),
    "app_name": APP_NAME,
    "bundle_identifier": info["CFBundleIdentifier"],
    "chromium_version": info["CFBundleShortVersionString"],
    "chromium_revision": build["chromium_revision"],
    "codec_args_sha256": build["args_sha256"],
    "architecture": "arm64",
    "signing": "Apple Development",
    "team_identifier": package["team_identifier"],
    "notarized": package["notarized"],
    "strict_nested_signatures_verified": True,
    "archive_round_trip_verified": True,
    "bundle_inventory_entries": len(baseline),
    "bundle_inventory_sha256": sha(OUTPUT / "bundle-inventory.json"),
    "requested_ui_sources_verified": len(request["ui_sources_sha256"]),
    "native_sources_verified": len(package["native_sources_sha256"]),
    "helper_sha256": package["helper_sha256"],
    "browser_executable_sha256": package["browser_executable_sha256"],
    "media_checks": media["media"]["playback"],
    "media_verification_sha256": sha(OUTPUT / "media-verification.json"),
    "prior_ui_tests": {"debug": 1015, "optimized": 1015, "refinement_focused": 82, "failures": 0},
    "limitations": ["Playback verified with isolated local fixtures; live Twitter session not exercised.", "Component screenshots and previous UI suites cover the chrome changes; integrated live-app screenshot not captured."],
    "installed": False,
    "published": False,
}
write_json(OUTPUT / "release-manifest.json", release)
(OUTPUT / "RELEASE-NOTES.md").write_text("""# WinMux Browser Alpha — Glass + Video, 2026-10-06 RC1

This Apple silicon package combines the completed H.264/AAC Chromium build with the Liquid Glass sidebar, browser header and native tab updates.

- Raised selected tabs remain clear when focus moves to another pane, with a separate keyboard-target ring.
- Sidebar rows are 28 points high, with 10-point leading icon padding and cached browser icons/loading indicators.
- Browser headers are 36 points high, with a 26-point rounded address field. Tab-strip joins retain square lower corners.
- MP4 and Media Source H.264/AAC and WebM VP9/Opus playback passed on the exact staged app, including decoded audio and video frames.

The ZIP was extracted and compared against the original bundle, including every file hash, symlink and permission. Strict nested signatures passed. All 30 requested UI source fingerprints match the packaged helper's provenance. Earlier UI verification passed 1,015 debug tests, 1,015 optimized tests and 82 focused refinement tests; those suites were not repeated during archive preparation.

The app is Apple Development signed and not notarized. The Chromium version remains 153.0.8010.53; the archive's RC1 identifier distinguishes this combined WinMux build. Live Twitter playback has not been tested; codec playback was verified with isolated local fixtures.

To install manually, first use the current app's Workspace Setup → Stop Workspace, quit the browser, and preserve the existing app and stopped-state data. Verify SHA256SUMS, extract the ZIP and copy WinMux Browser Alpha.app to Applications. Start Workspace from its final installed location. This packaging operation did not install or restart the app.
""")
assets = [archive, OUTPUT / "release-manifest.json", OUTPUT / "RELEASE-NOTES.md", OUTPUT / "package-manifest.json",
          OUTPUT / "bundle-inventory.json", OUTPUT / "media-verification.json", OUTPUT / "ui-verification.json", OUTPUT / "package-request.json"]
(OUTPUT / "SHA256SUMS").write_text("".join(sha(path) + "  " + path.name + "\n" for path in assets))
subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=OUTPUT, check=True)
request.update(status="complete", completed_at=datetime.now(timezone.utc).isoformat(),
               release_directory=str(OUTPUT), archive=str(archive), archive_sha256=release["archive_sha256"],
               release_manifest=str(OUTPUT / "release-manifest.json"))
write_json(REQUEST_PATH, request)
print(json.dumps({"archive": str(archive), "verified": True, "bytes": archive.stat().st_size}), flush=True)
