#!/usr/bin/env python3
"""Validate user-visible interaction traces. Transport/microbench results cannot qualify.

Input JSON: environment plus interactions. Timestamps use a shared monotonic
nanosecond clock and contain no page URLs, titles, search text or private data.
This evaluator consumes evidence; it does not collect or manufacture it.
"""
import argparse
import json
import math
from pathlib import Path
from collections import defaultdict

STAGES = ("input_received", "target_resolved", "request_issued", "activation_confirmed",
          "frame_presented", "input_ready")
LIMITS = {"warm_web": (50, 100), "frozen_web": (100, None), "native": (100, None),
          "mixed": (100, None), "space": (150, None)}
REQUIRED_EXTENSIONS = {"1password", "readwise", "cosmos"}


def percentile(values, quantile):
    return sorted(values)[math.ceil(len(values) * quantile) - 1]


def evaluate(data):
    problems = []
    environment = data.get("environment", {})
    for name in ("signed_build", "optimized_build", "blocking_enabled", "sandbox_enabled", "site_isolation_enabled"):
        if environment.get(name) is not True:
            problems.append(f"Required environment flag missing/false: {name}")
    if environment.get("clock") != "mach_continuous_nanoseconds":
        problems.append("All processes must use mach_continuous_nanoseconds")
    extensions = environment.get("extensions", {})
    if any(not isinstance(extensions.get(name), str) or not extensions[name] for name in REQUIRED_EXTENSIONS):
        problems.append("Required enabled extension versions are missing")
    if not environment.get("chromium_revision") or not environment.get("build_manifest_sha256"):
        problems.append("Missing immutable build provenance")
    refresh = environment.get("display_hz")
    if refresh not in (60, 120):
        problems.append("Qualification display_hz must be 60 or 120")
    groups = defaultdict(list)
    seen = set()
    for interaction in data.get("interactions", []):
        if set(interaction) != {"id", "run", "kind", "timestamps_ns", "evidence"}:
            problems.append("Unexpected interaction fields or missing fields; do not include browsing data")
            continue
        key = (interaction["run"], interaction["id"])
        if key in seen:
            problems.append("Duplicate interaction identity")
            continue
        seen.add(key)
        kind = interaction["kind"]
        times = interaction["timestamps_ns"]
        if kind not in LIMITS:
            problems.append(f"Unsupported interaction kind: {kind}")
            continue
        required = (*STAGES, "selection_visible")
        if set(times) != set(required) or any(type(times.get(stage)) is not int or times[stage] < 0 for stage in required):
            problems.append("Missing/invalid monotonic timestamps; acknowledgments are insufficient")
            continue
        if any(times[a] > times[b] for a, b in zip(STAGES, STAGES[1:])) or times["selection_visible"] < times["input_received"]:
            problems.append("Invalid event order or clock correlation")
            continue
        if interaction["evidence"] != {"presentation": "presentation_trace", "input_ready": "destination_input_probe"}:
            problems.append("A real presentation trace and destination input probe are required")
            continue
        groups[kind].append(interaction)
    metrics = {}
    for kind, items in groups.items():
        if len(items) < 1000 or len({i["run"] for i in items}) < 2:
            problems.append(f"{kind}: need at least 1,000 interactions over multiple runs")
            continue
        ready = [(i["timestamps_ns"]["input_ready"] - i["timestamps_ns"]["input_received"]) / 1e6 for i in items]
        feedback = [(i["timestamps_ns"]["selection_visible"] - i["timestamps_ns"]["input_received"]) / 1e6 for i in items]
        values = {"samples": len(items), "input_ready_p95_ms": percentile(ready, .95),
                  "input_ready_p99_ms": percentile(ready, .99), "selection_p95_ms": percentile(feedback, .95)}
        # Preserve stage distinctions; IPC ack is never substituted for a frame.
        values["stage_p95_ms"] = {stage: percentile([
            (i["timestamps_ns"][stage] - i["timestamps_ns"]["input_received"]) / 1e6 for i in items
        ], .95) for stage in STAGES[1:]}
        metrics[kind] = values
        p95_limit, p99_limit = LIMITS[kind]
        if values["input_ready_p95_ms"] > p95_limit or (p99_limit and values["input_ready_p99_ms"] > p99_limit):
            problems.append(f"{kind}: input-ready latency exceeds approved threshold")
        if refresh in (60, 120) and values["selection_p95_ms"] > (16.7 if refresh == 120 else 33.3):
            problems.append(f"{kind}: visible-selection latency exceeds two-frame threshold")
    missing = sorted(set(LIMITS) - set(metrics))
    if missing:
        problems.append("Missing qualified interaction kinds: " + ", ".join(missing))
    return {"scope": "interaction_latency_only", "passed": not problems,
            "daily_driver_qualified": False, "metrics": metrics, "problems": problems}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    options = parser.parse_args()
    result = evaluate(json.loads(options.trace.read_text()))
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
