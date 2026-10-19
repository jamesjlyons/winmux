import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import chromium
import prepare_ublock


class UBlockPackageTests(unittest.TestCase):
    def test_complete_component_is_reproducible_and_detects_tampering(self):
        with tempfile.TemporaryDirectory() as root:
            component = Path(root) / "component"
            provenance = prepare_ublock.prepare(component)
            self.assertEqual(provenance, prepare_ublock.prepare(component))
            prepare_ublock.validate(component, provenance)
            manifest = json.loads((component / "manifest.json").read_text())
            key_hash = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
            extension_id = "".join(chr(ord('a') + int(c, 16)) for c in key_hash)
            self.assertEqual(extension_id, provenance["extension_id"])
            self.assertEqual(manifest["manifest_version"], 2)
            self.assertIn("webRequestBlocking", manifest["permissions"])
            for resource in ["dashboard.html", "logger-ui.html", "js/scriptlet-filtering.js",
                             "js/cosmetic-filtering.js", "js/redirect-engine.js", "LICENSE.txt"]:
                self.assertTrue((component / resource).is_file(), resource)
            self.assertNotIn("__MSG_", json.dumps(manifest))
            (component / "js/start.js").write_text("tampered")
            with self.assertRaisesRegex(RuntimeError, "changed after preparation"):
                prepare_ublock.validate(component, provenance)

    def test_bad_archive_digest_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as root:
            inputs = Path(root) / "inputs"
            inputs.mkdir()
            (inputs / "bad.zip").write_bytes(b"not a zip")
            (inputs / "manifest.json").write_text(json.dumps({"archive": "bad.zip", "sha256": "0" * 64}))
            with self.assertRaisesRegex(RuntimeError, "checksum"):
                prepare_ublock.prepare(Path(root) / "component", inputs)
            self.assertFalse((Path(root) / "component").exists())

    def test_zip_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            inputs = Path(root) / "inputs"
            inputs.mkdir()
            archive = inputs / "bad.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("uBlock0.chromium/../../escaped", "bad")
            (inputs / "manifest.json").write_text(json.dumps({
                "archive": archive.name, "sha256": prepare_ublock.sha256(archive)}))
            with self.assertRaisesRegex(RuntimeError, "Unsafe"):
                prepare_ublock.prepare(Path(root) / "component", inputs)
            self.assertFalse((Path(root) / "escaped").exists())

    def test_filesystem_fallback_uses_exact_device(self):
        failure = subprocess.CalledProcessError(1, "diskutil")
        with patch.object(chromium, "output", side_effect=[
                "Filesystem 512-blocks Used Available Capacity Mounted on\n/dev/disk3s1 1 1 1 1% /System/Volumes/Data",
                "/dev/disk3s10 on /other (hfs, local)\n/dev/disk3s1 on /System/Volumes/Data (apfs, local)"]), \
                patch.object(chromium.subprocess, "check_output", side_effect=failure):
            self.assertEqual(chromium.filesystem(Path("/tmp")), "apfs")


if __name__ == "__main__":
    unittest.main()
