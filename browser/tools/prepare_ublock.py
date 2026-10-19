#!/usr/bin/env python3
"""Prepare the checksum-pinned, offline-capable uBlock component; no downloads."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
INPUTS = ROOT / "browser/ublock"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint():
    paths = sorted(p for p in INPUTS.iterdir() if p.is_file()) + [Path(__file__)]
    return hashlib.sha256(b"".join(p.name.encode() + b"\0" + p.read_bytes() for p in paths)).hexdigest()[:16]


def replace_once(path, before, after):
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError(f"uBlock integration anchor changed: {path.name}")
    path.write_text(text.replace(before, after))


def prepare(destination, inputs=INPUTS):
    destination = Path(destination)
    pin = json.loads((inputs / "manifest.json").read_text())
    archive = inputs / pin["archive"]
    if sha256(archive) != pin["sha256"]:
        raise RuntimeError("uBlock archive checksum mismatch")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ublock-", dir=destination.parent) as scratch:
        staging = Path(scratch) / "component"
        staging.mkdir()
        with zipfile.ZipFile(archive) as zipped:
            if sum(i.file_size for i in zipped.infolist()) > 64 * 1024 * 1024:
                raise RuntimeError("uBlock archive exceeds unpacked size limit")
            for entry in zipped.infolist():
                path = PurePosixPath(entry.filename)
                if (path.is_absolute() or ".." in path.parts or
                        not path.parts or path.parts[0] != "uBlock0.chromium" or
                        (entry.external_attr >> 16) & 0o170000 == 0o120000):
                    raise RuntimeError("Unsafe uBlock archive entry")
                relative = Path(*path.parts[1:])
                if entry.is_dir():
                    (staging / relative).mkdir(parents=True, exist_ok=True)
                else:
                    target = staging / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(zipped.read(entry))
        manifest_path = staging / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if manifest["version"] != pin["version"] or manifest["manifest_version"] != 2:
            raise RuntimeError("Unexpected uBlock version or manifest")
        manifest["key"] = pin["key"]
        manifest["permissions"] = [p for p in manifest["permissions"] if p != "dns"]
        # ComponentLoader does not localize a disk-backed manifest itself.
        messages = json.loads((staging / "_locales/en/messages.json").read_text())
        def localize(value):
            if isinstance(value, dict):
                return {k: localize(v) for k, v in value.items()}
            if isinstance(value, list):
                return [localize(v) for v in value]
            if isinstance(value, str) and value.startswith("__MSG_") and value.endswith("__"):
                return messages[value[6:-2]]["message"]
            return value
        manifest_path.write_text(json.dumps(localize(manifest), indent=2) + "\n")
        shutil.copy2(inputs / "winmux.js", staging / "js/winmux.js")
        shutil.copy2(inputs / "NOTICE.txt", staging / "WINMUX-NOTICE.txt")
        replace_once(staging / "js/start.js", "let lastVersionInt = 0;",
                     "await import('./winmux.js');\n\nlet lastVersionInt = 0;")
        replace_once(staging / "js/start.js", "µb.readyToFilter = true;",
                     "µb.readyToFilter = true;\nawait globalThis.winmuxBlockingReady();")
        replace_once(staging / "js/assets.js", "assets.fetch = function(url, options = {}) {",
                     "assets.fetch = function(url, options = {}) {\n"
                     "    if ( /^[a-z-]+:\\/\\//i.test(url) && !url.startsWith(browser.runtime.getURL('')) && globalThis.winmuxFilterUpdatesAllowed !== true ) {\n"
                     "        // Match assets.fetch's failure contract so list loading can use bundled fallbacks.\n"
                     "        return Promise.reject({ url, content: '', error: 'Filter updates are disabled in WinMux Privacy Settings' });\n"
                     "    }")
        replace_once(staging / "js/assets.js", "assets.updateStart = function(details) {",
                     "assets.updateStart = function(details) {\n"
                     "    if ( globalThis.winmuxFilterUpdatesAllowed !== true ) { return; }")
        replace_once(staging / "js/assets.js", "const getAssetDiffDetails = assetKey => {",
                     "const getAssetDiffDetails = assetKey => {\n"
                     "    if ( globalThis.winmuxFilterUpdatesAllowed !== true ) { return; }")
        replace_once(staging / "js/assets.js", "        worker.onmessage = ev => {",
                     "        worker.onmessage = ev => {\n"
                     "            if ( globalThis.winmuxFilterUpdatesAllowed !== true ) { terminate(); return; }")
        hashes = {str(p.relative_to(staging)): sha256(p) for p in staging.rglob("*") if p.is_file()}
        if destination.exists():
            current = {str(p.relative_to(destination)): sha256(p) for p in destination.rglob("*") if p.is_file()}
            if current != hashes:
                raise RuntimeError("uBlock output differs; choose a new output directory")
        else:
            shutil.copytree(staging, destination)
    return {"version": pin["version"], "extension_id": pin["extension_id"],
            "archive_sha256": pin["sha256"], "files_sha256": hashes,
            "source_sha256": {str(p.relative_to(ROOT)): sha256(p) for p in
                              [p for p in INPUTS.iterdir() if p.is_file()] + [Path(__file__)]}}


def validate(directory, manifest):
    directory = Path(directory)
    actual = {str(p.relative_to(directory)): sha256(p) for p in directory.rglob("*") if p.is_file()}
    if actual != manifest["files_sha256"]:
        raise RuntimeError("uBlock component changed after preparation")
    for name, expected in manifest["source_sha256"].items():
        if sha256(ROOT / name) != expected:
            raise RuntimeError("uBlock source changed after preparation")
