#!/usr/bin/env python3
"""Check a read-only environment recording; never qualify benchmark performance.

Input is JSONL from observe_environment.swift. Flags interruptions without reading
apps, profiles, accounts or accessibility. A consistent recording must still be
correlated with the full benchmark interval and matched build/workload evidence.
"""
import argparse
import json
import math
from pathlib import Path
import re


def evaluate(records):
    invalid, conditions = [], []
    result = {"scope": "benchmark_environment_only", "benchmark_qualified": False,
              "milestone_0_qualified": False, "valid_observation": False,
              "conditions_consistent": False, "observation_problems": invalid,
              "condition_problems": conditions,
              "unverified": ["Full benchmark interval is covered by this recording",
                             "Correct tab/window is visible and receiving input",
                             "Equivalent builds, extensions, profiles and workloads",
                             "Background workload, display frame cadence and repeatability"]}
    if (not isinstance(records, list) or len(records) < 4
            or any(not isinstance(item, dict) for item in records)
            or records[0].get("type") != "metadata"
            or records[-1].get("type") != "completion"):
        invalid.append("Missing recording boundaries or incomplete output")
        return result
    meta, completion = records[0], records[-1]
    if meta.get("schema_version") != 1 or meta.get("scope") != "benchmark_environment_observation_only":
        invalid.append("Unsupported recording format")
    duration, interval = meta.get("requested_seconds"), meta.get("interval_seconds")
    if any(type(value) not in (int, float) or not math.isfinite(value) or value <= 0
           for value in (duration, interval)):
        invalid.append("Invalid recording duration/interval")
        return result
    if completion.get("complete") is not True:
        invalid.append("Recorder did not complete")
    source_hash = meta.get("target_executable_sha256")
    if not isinstance(source_hash, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", source_hash) or completion.get("target_executable_sha256") != source_hash:
        invalid.append("Missing or changed target executable hash")
    if not re.fullmatch(r"[a-fA-F0-9]{64}", str(meta.get("collector_executable_sha256", ""))):
        invalid.append("Missing collector executable hash")
    samples = records[1:-1]
    if any(item.get("type") != "sample" or any(type(item.get(k)) is not int or item[k] < 0
           for k in ("continuous_ns", "awake_ns")) for item in samples):
        invalid.append("Invalid sample/clock records")
        return result
    if samples[0].get("reason") != "start" or samples[-1].get("reason") != "end":
        invalid.append("Missing start/end samples")
    elapsed = (samples[-1]["continuous_ns"] - samples[0]["continuous_ns"]) / 1e9
    if elapsed < duration:
        invalid.append("Incomplete observation window")
    if completion.get("target_identity_matches") is not True or any(
            s.get("target_identity_matches") is not True for s in samples):
        invalid.append("Target exited, changed executable or reused PID")
    for a, b in zip(samples, samples[1:]):
        delta = b["continuous_ns"] - a["continuous_ns"]
        awake = b["awake_ns"] - a["awake_ns"]
        if delta <= 0 or awake <= 0:
            invalid.append("Non-monotonic sample clocks")
        if delta > (interval + max(1, interval * .2)) * 1e9:
            invalid.append("Sampling gap exceeded the allowed interval")
        if abs(delta - awake) > 100_000_000:
            conditions.append("System sleep interrupted the observation")
    first_displays = samples[0].get("displays")
    for item in samples:
        if item.get("target_foreground") is not True or item.get("activated_target") is False:
            conditions.append("Target was not continuously observed as foreground")
        if item.get("reason") in ("will_sleep", "did_wake"):
            conditions.append("System sleep interrupted the observation")
        if item.get("thermal_state") != 0 or type(item.get("thermal_state")) is not int:
            conditions.append("Thermal state was not nominal throughout")
        if item.get("low_power_mode") is not False:
            conditions.append("Low Power Mode was enabled or unknown")
        if item.get("power_source") != "AC Power":
            conditions.append("AC power was not observed throughout")
        displays = item.get("displays")
        if not isinstance(displays, list) or not displays or any(not isinstance(d, dict) or
                d.get("mode_available") is not True for d in displays):
            conditions.append("Display configuration unavailable")
        elif any(type(d.get("refresh_hz")) not in (float, int) or not math.isfinite(d["refresh_hz"])
                 or d["refresh_hz"] <= 0 for d in displays):
            conditions.append("Display refresh rate unknown or variable")
        if displays != first_displays:
            conditions.append("Display configuration changed")
    result.update(valid_observation=not invalid, conditions_consistent=not invalid and not conditions,
                  elapsed_seconds=elapsed, samples=len(samples),
                  observation_problems=sorted(set(invalid)), condition_problems=sorted(set(conditions)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    args = parser.parse_args()
    records = [json.loads(line) for line in args.recording.read_text().splitlines() if line]
    result = evaluate(records)
    print(json.dumps(result, indent=2))
    return 0 if result["conditions_consistent"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
