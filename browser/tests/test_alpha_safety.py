import copy
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_alpha
import package_alpha


class AlphaSafetyTests(TestCase):
    def test_live_build_excludes_duplicate_builds_and_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with build_alpha.acquire_engine_lock(root):
                for exclusive in (True, False):
                    with self.assertRaisesRegex(RuntimeError, "concurrent build"):
                        build_alpha.acquire_engine_lock(root, exclusive=exclusive)
            with build_alpha.acquire_engine_lock(root, exclusive=False):
                with self.assertRaises(RuntimeError):
                    build_alpha.acquire_engine_lock(root)

    def test_resume_accepts_owned_patch_but_preserves_unrelated_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.PIPE)
            git("init")
            source = root / "source.cc"
            source.write_text("before\n")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture")
            source.write_text("owned change\n")
            patch = git("diff", "--binary", "--full-index", "HEAD")
            git("config", "core.abbrev", "12")
            self.assertTrue(build_alpha.owned_patch_state(root, patch))
            source.write_text("unrelated work\n")
            with self.assertRaisesRegex(RuntimeError, "Unowned"):
                build_alpha.owned_patch_state(root, patch)
            self.assertEqual(source.read_text(), "unrelated work\n")
            source.write_text("before\n")
            self.assertFalse(build_alpha.owned_patch_state(root, patch))

    def test_packaging_rejects_failed_control_stale_and_escaping_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "chrome/browser/winmux/workspace_bridge.mm"
            source = root / name
            source.parent.mkdir(parents=True)
            source.write_bytes(b"compiled alpha source")
            manifest = {
                "configuration": "alpha-transport-proof", "build_succeeded": True,
                "chromium_revision": package_alpha.chromium.PINS["chromium"]["revision"],
                "args_sha256": package_alpha.sha256(package_alpha.ROOT / "browser/chromium/args.gn"),
                "patch_sha256": package_alpha.sha256(package_alpha.ROOT / "browser/chromium/patches/0001-workspace-bridge.patch"),
                "overlay_sha256": {name: hashlib.sha256(source.read_bytes()).hexdigest()},
            }
            package_alpha.validate_manifest(manifest, root)
            for change in ({"build_succeeded": False}, {"configuration": "browser-only-control"},
                           {"patch_sha256": "stale"}, {"overlay_sha256": {"../outside": "hash"}}):
                invalid = {**copy.deepcopy(manifest), **change}
                with self.subTest(change=change), self.assertRaises(RuntimeError):
                    package_alpha.validate_manifest(invalid, root)
            source.write_bytes(b"new uncompiled edit")
            with self.assertRaisesRegex(RuntimeError, "changed since compilation"):
                package_alpha.validate_manifest(manifest, root)
