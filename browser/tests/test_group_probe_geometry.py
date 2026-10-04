import copy
from pathlib import Path
import sys
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "script/benchmarks"))
from group_probe_geometry import inventory_signature, require_same_inventory, scope_window_snapshot


class GroupProbeGeometryTests(TestCase):
    def surfaces(self):
        return [dict(id="browser:one", workspace="1", available=True, browser=dict(hostWindowID=10)),
                dict(id="native:two", workspace="2", available=True, nativeWindowID=20)]

    def window(self, window_id, pid, onscreen=True):
        return dict(id=window_id, pid=pid, onscreen=onscreen, bounds=dict(X=10, Y=30, Width=800, Height=600))

    def test_scope_uses_inventory_ids_and_records_auxiliary_windows_regardless_of_size(self):
        inventory = inventory_signature(self.surfaces())
        windows = [self.window(10, 100), self.window(20, 200), self.window(30, 100), self.window(40, 200)]
        managed, other = scope_window_snapshot(windows, 100, inventory)
        self.assertEqual(set(managed), {"10", "20"})
        self.assertEqual(other, {"30": windows[2]["bounds"]})

    def test_wrong_pid_hidden_or_missing_original_host_cannot_be_replaced_by_another_window(self):
        inventory = inventory_signature(self.surfaces())
        for original in ([], [self.window(10, 999)], [self.window(10, 100, onscreen=False)]):
            with self.subTest(original=original):
                managed, other = scope_window_snapshot(original + [self.window(30, 100)], 100, inventory)
                self.assertEqual(managed, {})
                self.assertEqual(set(other), {"30"})

    def test_inventory_rejects_added_removed_replaced_moved_or_unavailable_surfaces(self):
        surfaces = self.surfaces()
        expected = inventory_signature(surfaces)
        require_same_inventory(expected, list(reversed(surfaces)))
        variants = [surfaces[:1], surfaces + [dict(id="browser:extra", workspace="1", available=True, browser=dict(hostWindowID=30))]]
        for key, value in (("workspace", "3"), ("available", False), ("browser", dict(hostWindowID=30))):
            changed = copy.deepcopy(surfaces)
            changed[0][key] = value
            variants.append(changed)
        for changed in variants:
            with self.subTest(surfaces=changed), self.assertRaisesRegex(RuntimeError, "inventory changed"):
                require_same_inventory(expected, changed)

    def test_available_surface_without_host_or_duplicate_identity_is_rejected(self):
        for surfaces in ([dict(id="browser:one", workspace="1", available=True, browser={})], self.surfaces() * 2):
            with self.subTest(surfaces=surfaces), self.assertRaises(RuntimeError):
                inventory_signature(surfaces)
