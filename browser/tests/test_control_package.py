import copy
from pathlib import Path
import sys
import tempfile
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import package_control


class ControlPackageTests(TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.build = Path(self.directory.name) / "archive"
        self.build.mkdir()
        args = package_control.chromium.CONFIG / "args.gn"
        (self.build / "args.gn").write_bytes(args.read_bytes())
        self.manifest = {
            "configuration": "browser-only-control",
            "pins": copy.deepcopy(package_control.chromium.PINS),
            "args_sha256": package_control.sha256(args),
        }

    def test_alpha_failed_build_and_stale_pins_are_refused(self):
        # Original control manifests predate build_succeeded; an explicit failure
        # is still rejected. Matching completed control provenance is accepted.
        package_control.validate_control(self.manifest, self.build)
        for key, value in (("configuration", "alpha-milestone-0"), ("build_succeeded", False)):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                package_control.validate_control({**self.manifest, key: value}, self.build)
        for component in ("chromium", "depot_tools"):
            manifest = copy.deepcopy(self.manifest)
            manifest["pins"][component]["revision"] = "wrong"
            with self.subTest(component=component), self.assertRaises(RuntimeError):
                package_control.validate_control(manifest, self.build)

    def test_changed_configuration_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "configuration"):
            package_control.validate_control({**self.manifest, "args_sha256": "wrong"}, self.build)
        (self.build / "args.gn").write_text("unrelated build arguments")
        with self.assertRaisesRegex(RuntimeError, "arguments have changed"):
            package_control.validate_control(self.manifest, self.build)

    def test_downstream_artifacts_are_refused(self):
        for relative in ("Contents/Helpers/WinMuxWorkspaceHelper",
                         "Contents/Frameworks/Chromium Framework.framework/Libraries/libwinmux_blocking.dylib"):
            artifact = self.build / "Chromium.app" / relative
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.touch()
            with self.subTest(relative=relative), self.assertRaisesRegex(RuntimeError, "downstream"):
                package_control.validate_control(self.manifest, self.build)
            artifact.unlink()

    def test_staging_cannot_overwrite_or_mutate_control_through_symlinks(self):
        root = Path(self.directory.name)
        symlink = root / "alias"
        symlink.symlink_to(self.build, target_is_directory=True)
        for destination in (self.build / "new", symlink / "new", root):
            with self.subTest(destination=destination), self.assertRaises(RuntimeError):
                package_control.validate_output(destination, self.build)
        self.assertFalse((self.build / "new").exists())
        self.assertEqual(package_control.validate_output(root / "safe", self.build), (root / "safe").resolve())
