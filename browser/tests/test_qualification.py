import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from qualify_interactions import evaluate, STAGES, LIMITS


def fixture():
    # Synthetic data is only for evaluator tests, never saved as measurement proof.
    return {"environment": {
        "signed_build": True, "optimized_build": True, "blocking_enabled": True,
        "sandbox_enabled": True, "site_isolation_enabled": True,
        "clock": "mach_continuous_nanoseconds", "display_hz": 120,
        "extensions": {"1password": "test", "readwise": "test", "cosmos": "test"},
        "chromium_revision": "test-only", "build_manifest_sha256": "test-only",
    }, "interactions": [{"id": str(i), "run": str(i % 3), "kind": kind,
        "timestamps_ns": {**{stage: index * 1_000_000 for index, stage in enumerate(STAGES)}, "selection_visible": 1_000_000},
        "evidence": {"presentation": "presentation_trace", "input_ready": "destination_input_probe"},
    } for kind in LIMITS for i in range(1000 * list(LIMITS).index(kind), 1000 * (list(LIMITS).index(kind) + 1))]}


class QualificationTests(unittest.TestCase):
    def test_complete_fixture_qualifies_only_interactions(self):
        result = evaluate(fixture())
        self.assertTrue(result["passed"], result["problems"])
        self.assertFalse(result["daily_driver_qualified"])

    def test_fast_ack_with_slow_content_fails(self):
        data = fixture()
        for item in data["interactions"]:
            item["timestamps_ns"]["input_ready"] = 200_000_000
        self.assertFalse(evaluate(data)["passed"])

    def test_missing_presentation_or_input_evidence_fails(self):
        for field in ("frame_presented", "input_ready"):
            data = fixture()
            for item in data["interactions"]:
                del item["timestamps_ns"][field]
            self.assertFalse(evaluate(data)["passed"])

    def test_disabled_extensions_blocker_sandbox_or_low_sample_size_fail(self):
        for field in ("blocking_enabled", "sandbox_enabled", "site_isolation_enabled"):
            data = fixture()
            data["environment"][field] = False
            self.assertFalse(evaluate(data)["passed"])
        data = fixture()
        data["environment"]["extensions"] = {}
        self.assertFalse(evaluate(data)["passed"])
        data = fixture()
        data["interactions"] = data["interactions"][:999]
        self.assertFalse(evaluate(data)["passed"])

    def test_duplicates_browsing_data_and_clock_disorder_fail(self):
        data = fixture()
        data["interactions"].append(copy.deepcopy(data["interactions"][0]))
        self.assertFalse(evaluate(data)["passed"])
        data = fixture()
        data["interactions"][0]["url"] = "private.test"
        self.assertFalse(evaluate(data)["passed"])
        data = fixture()
        data["interactions"][0]["timestamps_ns"]["activation_confirmed"] = 99_000_000
        self.assertFalse(evaluate(data)["passed"])


if __name__ == "__main__":
    unittest.main()
