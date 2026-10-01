import copy
import sys
from pathlib import Path
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from measure_helper import summarize


def series():
    # A known 0.5%-of-one-core workload over exactly five minutes.
    return [{"continuous_ns": i * 5_000_000_000,
             "awake_ns": i * 5_000_000_000,
             "cpu_ns": i * 25_000_000,
             "physical_footprint_bytes": 4 * 1024 * 1024,
             "resident_bytes": 32 * 1024 * 1024,
             "process_start_ticks": 1234, "executable_uuid": "fixture"}
            for i in range(61)]


class HelperMeasurementTests(TestCase):
    def test_cpu_uses_one_core_and_memory_uses_footprint_not_rss(self):
        result = summarize(series(), 300, 5)
        self.assertTrue(result["valid_series"])
        self.assertAlmostEqual(result["metrics"]["average_cpu_percent_one_core"], .5)
        self.assertEqual(result["metrics"]["sampled_max_physical_footprint_bytes"], 4 * 1024 * 1024)
        self.assertNotIn("passed", result)

    def test_reused_pid_cannot_blend_two_processes(self):
        data = series()
        data[-1]["process_start_ticks"] += 1
        result = summarize(data, 300, 5)
        self.assertFalse(result["valid_series"])
        self.assertEqual(result["metrics"], {})

    def test_sleep_cannot_dilute_the_cpu_average(self):
        data = series()
        for sample in data[30:]:
            sample["continuous_ns"] += 60_000_000_000
        result = summarize(data, 300, 5)
        self.assertIn("System sleep interrupted the sample window", result["problems"])
        self.assertEqual(result["metrics"], {})

    def test_short_window_does_not_qualify_as_five_minutes(self):
        self.assertFalse(summarize(series()[:-1], 300, 5)["valid_series"])
        self.assertFalse(summarize([], 300, 5)["valid_series"])

    def test_missing_samples_and_counter_regression_are_rejected(self):
        data = series()
        self.assertFalse(summarize(data[:20] + data[22:], 300, 5)["valid_series"])
        regressed = copy.deepcopy(data)
        regressed[-1]["cpu_ns"] = 0
        self.assertFalse(summarize(regressed, 300, 5)["valid_series"])

    def test_duplicate_or_backwards_clocks_are_rejected(self):
        for clock in ("continuous_ns", "awake_ns"):
            data = series()
            data[-1][clock] = data[-2][clock]
            self.assertFalse(summarize(data, 300, 5)["valid_series"])
