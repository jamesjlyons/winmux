import copy
from pathlib import Path
import sys
import tempfile
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from speedometer_fixture import asset_manifest, page_conditions


def report():
    state = dict(wall_ms=1000, monotonic_ms=100, focused=True,
                 visibility="visible", width=1200, height=800, device_pixel_ratio=2)
    return dict(start=state, end={**state, "wall_ms": 2000, "monotonic_ms": 1100}, events=[])


class SpeedometerFixtureTests(TestCase):
    def test_visible_stable_page_and_transient_interruptions(self):
        self.assertEqual(page_conditions(report()), [])
        for change in (dict(focused=False), dict(visibility="hidden"),
                       dict(width=800), dict(height=600), dict(device_pixel_ratio=1)):
            value = report()
            value["events"] = [{**copy.deepcopy(value["start"]), **change}]
            with self.subTest(change=change):
                self.assertTrue(page_conditions(value))

    def test_invalid_interval_is_rejected(self):
        value = report()
        value["end"]["monotonic_ms"] = value["start"]["monotonic_ms"]
        self.assertIn("Non-positive benchmark interval", page_conditions(value))

    def test_asset_identity_includes_paths_contents_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "index.html").write_text("first")
            initial = asset_manifest(root)
            self.assertEqual(initial["files"], 1)
            (root / "index.html").write_text("second")
            self.assertNotEqual(initial, asset_manifest(root))
            before_move = asset_manifest(root)
            (root / "index.html").rename(root / "other.html")
            self.assertNotEqual(before_move, asset_manifest(root))
            (root / "link.html").symlink_to(root / "other.html")
            with self.assertRaises(ValueError):
                asset_manifest(root)
