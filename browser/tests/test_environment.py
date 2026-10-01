import copy
from pathlib import Path
import sys
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from check_environment import evaluate


def fixture():
    metadata = {"type": "metadata", "schema_version": 1,
                "scope": "benchmark_environment_observation_only", "requested_seconds": 4,
                "interval_seconds": 2, "target_executable_sha256": "a" * 64,
                "collector_executable_sha256": "c" * 64}
    samples = [{"type": "sample", "reason": reason, "continuous_ns": (i * 2 + 10) * 10**9,
                "awake_ns": (i * 2 + 5) * 10**9, "target_identity_matches": True,
                "target_foreground": True, "thermal_state": 0, "low_power_mode": False,
                "power_source": "AC Power", "displays": [{"mode_available": True, "refresh_hz": 60}]}
               for i, reason in enumerate(("start", "interval", "end"))]
    return [metadata, *samples, {"type": "completion", "complete": True,
                               "target_identity_matches": True, "target_executable_sha256": "a" * 64}]


class EnvironmentTests(TestCase):
    def test_consistent_environment_never_qualifies_benchmark(self):
        result = evaluate(fixture())
        self.assertTrue(result["conditions_consistent"])
        self.assertTrue(result["valid_observation"])
        self.assertFalse(result["benchmark_qualified"])
        self.assertFalse(result["milestone_0_qualified"])

    def test_brief_focus_loss_is_detected_even_when_periodic_samples_are_focused(self):
        records = fixture()
        event = {**copy.deepcopy(records[1]), "reason": "activation", "activated_target": False}
        event["continuous_ns"] += 10_000_000
        event["awake_ns"] += 10_000_000
        records.insert(2, event)
        result = evaluate(records)
        self.assertTrue(result["valid_observation"])
        self.assertIn("Target was not continuously observed as foreground", result["condition_problems"])

    def test_thermal_power_unknown_focus_and_display_changes_are_flagged(self):
        for key, value in (("target_foreground", None), ("thermal_state", 1),
                           ("low_power_mode", True), ("power_source", "Battery Power"),
                           ("displays", []), ("displays", [{"mode_available": True, "refresh_hz": 0}]),
                           ("displays", [{"mode_available": True, "refresh_hz": 120}])):
            records = fixture()
            records[2][key] = value
            with self.subTest(key=key, value=value):
                self.assertFalse(evaluate(records)["conditions_consistent"])

    def test_sleep_clock_gap_and_process_reuse_are_not_accepted(self):
        for change in (lambda r: r[2].update(awake_ns=r[2]["awake_ns"] - 200_000_000),
                       lambda r: r[2].update(continuous_ns=r[1]["continuous_ns"]),
                       lambda r: r[2].update(target_identity_matches=False),
                       lambda r: r[-1].update(target_executable_sha256="b" * 64)):
            records = fixture()
            change(records)
            self.assertFalse(evaluate(records)["conditions_consistent"])
        records = fixture()
        records[0]["interval_seconds"] = .25
        self.assertFalse(evaluate(records)["valid_observation"])

    def test_incomplete_and_malformed_records_fail_closed(self):
        records = fixture()
        for changed in (records[:-1], [], [None, *records[1:]], [*records, records[-1]],
                        [{**records[0], "collector_executable_sha256": None}, *records[1:]],
                        [{**records[0], "requested_seconds": 300}, *records[1:]],
                        [{**records[0], "requested_seconds": float('nan')}, *records[1:]],
                        [records[0], {**records[1], "awake_ns": None}, *records[2:]]):
            with self.subTest(changed=changed):
                self.assertFalse(evaluate(changed)["valid_observation"])
