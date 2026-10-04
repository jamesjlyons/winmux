import copy
from datetime import datetime, timezone
from pathlib import Path
import sys
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from summarize_speedometer import inspect_run
from test_environment import fixture


def pair():
    env = fixture()
    env[0]["recorded_utc"] = "2026-10-01T12:00:00Z"
    epoch = datetime(2026, 10, 1, 12, tzinfo=timezone.utc).timestamp() * 1000
    start = dict(wall_ms=epoch + 1500, monotonic_ms=100, focused=True,
                 visibility="visible", width=1500, height=863, device_pixel_ratio=2)
    end = {**start, "wall_ms": epoch + 3500, "monotonic_ms": 2100}
    return dict(run="control-1", result=dict(start=start, end=end, events=[], metrics={"Score": {"values": [4.] * 10}})), env


class SpeedometerSummaryTests(TestCase):
    def test_full_interval_must_be_covered(self):
        report, env = pair()
        self.assertTrue(inspect_run(report, env)["conditions_consistent"])
        report["result"]["start"]["wall_ms"] -= 1000
        self.assertFalse(inspect_run(report, env)["conditions_consistent"])

    def test_cleanup_boundary_does_not_hide_actual_focus_interruption(self):
        report, env = pair()
        report["result"]["end"]["focused"] = False
        result = inspect_run(report, env)
        self.assertTrue(result["completion_after_focused_iframe_cleanup"])
        self.assertTrue(result["conditions_consistent"])
        report["result"]["events"] = [{**copy.deepcopy(report["result"]["start"]), "focused": False}]
        self.assertFalse(inspect_run(report, env)["conditions_consistent"])

    def test_partial_nonfinite_scores_and_hidden_page_are_rejected(self):
        for values in ([4.] * 9, [float("nan")] * 10, [0.] * 10):
            report, env = pair()
            report["result"]["metrics"]["Score"]["values"] = values
            self.assertFalse(inspect_run(report, env)["conditions_consistent"])
        report, env = pair()
        report["result"]["end"]["visibility"] = "hidden"
        self.assertFalse(inspect_run(report, env)["conditions_consistent"])
