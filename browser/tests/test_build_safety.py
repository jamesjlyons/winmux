import sys
from pathlib import Path
from unittest import TestCase, mock
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import chromium


class BuildSafetyTests(TestCase):
    def test_insufficient_storage_blocks_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "not-created"
            with mock.patch.object(chromium.shutil, "disk_usage", return_value=mock.Mock(free=108 * chromium.GIB)), mock.patch.object(chromium, "filesystem", return_value="apfs"):
                report = chromium.preflight(root, "fetch")
            self.assertTrue(any("200 GiB" in reason for reason in report["blockers"]))
            self.assertFalse(root.exists())

    def test_wrong_filesystem_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(chromium.shutil, "disk_usage", return_value=mock.Mock(free=500 * chromium.GIB)), mock.patch.object(chromium, "filesystem", return_value="exfat"):
                report = chromium.preflight(Path(directory), "fetch")
            self.assertIn("Chromium requires an APFS build volume.", report["blockers"])

    def test_existing_nonrepo_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "precious-file"
            marker.write_text("keep me")
            with self.assertRaises(RuntimeError):
                chromium.ensure_clone(root, chromium.PINS["chromium"])
            self.assertEqual(marker.read_text(), "keep me")

    def test_different_revision_is_not_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".git").mkdir()
            with mock.patch.object(chromium, "output", return_value="different"), mock.patch.object(chromium, "run") as run:
                with self.assertRaises(RuntimeError):
                    chromium.ensure_clone(root, chromium.PINS["chromium"])
                run.assert_not_called()

    def test_dirty_checkout_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".git").mkdir()
            with mock.patch.object(chromium, "output", side_effect=[chromium.PINS["chromium"]["revision"], "M work"]), mock.patch.object(chromium, "run") as run:
                with self.assertRaises(RuntimeError):
                    chromium.ensure_clone(root, chromium.PINS["chromium"])
                run.assert_not_called()
