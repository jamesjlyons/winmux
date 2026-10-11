from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import TestCase, mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_alpha


class V8PatchProvenanceTests(TestCase):
    def test_rejects_different_v8_revision(self):
        deps = "'v8_revision': '" + "a" * 40 + "',"
        with mock.patch.object(subprocess, "check_output", return_value=deps), \
                mock.patch.object(build_alpha.chromium, "output", return_value="b" * 40):
            with self.assertRaisesRegex(RuntimeError, "Unexpected V8 revision"):
                build_alpha.v8_patch_inputs(Path("/unused"))

    def test_rejects_missing_revision(self):
        with mock.patch.object(subprocess, "check_output", return_value="{}"):
            with self.assertRaisesRegex(RuntimeError, "Missing pinned V8"):
                build_alpha.v8_patch_inputs(Path("/unused"))

    def test_new_patch_file_is_owned_and_later_edits_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.run(["git", *args], cwd=root, check=True,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            git("init")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "commit", "--allow-empty", "-m", "baseline")
            patch = root / "new.patch"
            patch.write_text("--- /dev/null\n+++ b/new.h\n@@ -0,0 +1 @@\n+owned\n")
            self.assertEqual(build_alpha.owned_patch_prefix(root, [patch]), 0)
            git("apply", "--intent-to-add", str(patch))
            self.assertEqual(build_alpha.owned_patch_prefix(root, [patch]), 1)
            (root / "new.h").write_text("unowned\n")
            with self.assertRaisesRegex(RuntimeError, "Unowned Chromium changes"):
                build_alpha.owned_patch_prefix(root, [patch])
