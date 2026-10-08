import sys
from pathlib import Path
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from test_browser_tab_speed import evaluate, summary, targets_met


class TabSpeedEvidenceTests(TestCase):
    def samples(self):
        return [dict(operation=kind, kind=kind, command_us=1_000_000,
                     inventory_us=1_010_000, layout_us=1_020_000,
                     input_ack_us=1_080_000,
                     favicon_observed_us=1_005_000 if kind == "cached_url" else None)
                for kind in ("blank", "cached_url")]

    def test_standard_median_and_nearest_rank_p95(self):
        self.assertEqual(summary([4, 1, 2, 3]), {"samples": 4, "median_ms": 2.5, "p95_ms": 4})
        self.assertIsNone(summary([]))

    def test_focus_or_input_acknowledgement_without_presentation_cannot_qualify(self):
        metrics = evaluate(self.samples(), {"blank": {"warm_window_ready": 1_005_000}})
        self.assertEqual(metrics["blank"]["input"]["p95_ms"], 80)
        self.assertFalse(targets_met(metrics, 1))

    def test_matching_real_presentation_and_cached_icon_can_meet_fixture_targets(self):
        events = {kind: {"warm_window_ready": 1_005_000, "presented": 1_090_000}
                  for kind in ("blank", "cached_url")}
        metrics = evaluate(self.samples(), events)
        self.assertEqual(metrics["cached_url"]["favicon_after_inventory"]["p95_ms"], 0)
        self.assertTrue(targets_met(metrics, 1))
        self.assertFalse(targets_met(metrics, 2), "Incomplete samples cannot qualify")

    def test_cached_url_input_and_presentation_must_also_meet_target(self):
        rows = self.samples()
        rows[1]["input_ack_us"] = 1_101_000
        events = {kind: {"warm_window_ready": 1_005_000, "presented": 1_090_000}
                  for kind in ("blank", "cached_url")}
        self.assertFalse(targets_met(evaluate(rows, events), 1))
        rows[1]["input_ack_us"] = 1_080_000
        del events["cached_url"]["presented"]
        self.assertFalse(targets_met(evaluate(rows, events), 1))

    def test_clock_mismatch_or_old_presentation_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Non-monotonic"):
            evaluate(self.samples(), {"blank": {"presented": 10}})
