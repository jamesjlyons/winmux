#!/usr/bin/env python3
"""Summarize paired development Speedometer runs, preserving measurement limits."""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import statistics

from check_environment import evaluate
from speedometer_fixture import page_conditions


def inspect_run(report, environment):
    context = evaluate(environment)
    problems = context["observation_problems"] + context["condition_problems"]
    result = report["result"]
    page_problems = page_conditions(result)
    # The pinned runner removes its last focused iframe before invoking the
    # completion callback (benchmark-runner.mjs:395). hasFocus() can be false at
    # this boundary even with a continuously foreground browser. Keep the raw
    # observation, but distinguish it from an actual blur/visibility interruption.
    cleanup_focus_boundary = (result["start"]["focused"] is True and result["end"]["focused"] is False
                              and all(event["focused"] is True for event in result["events"])
                              and all(state["visibility"] == "visible"
                                      for state in [result["start"], *result["events"], result["end"]]))
    if cleanup_focus_boundary:
        page_problems = [p for p in page_problems if p != "Page was hidden or unfocused"]
    problems += page_problems
    score = result["metrics"]["Score"]
    values = score["values"]
    if (not isinstance(values, list) or len(values) != 10 or
            any(type(x) not in (int, float) or not math.isfinite(x) or x <= 0 for x in values)):
        problems.append("Expected ten positive finite iteration scores")
        mean = None
    else:
        mean = statistics.mean(values)
    # The original native timestamp has one-second resolution. Use conservative
    # boundaries, leaving that uncertainty outside the measured page interval.
    meta = environment[0]
    recorded = datetime.fromisoformat(meta["recorded_utc"].replace("Z", "+00:00")).timestamp() * 1000
    end = recorded + context.get("elapsed_seconds", 0) * 1000
    if result["start"]["wall_ms"] < recorded + 1000 or result["end"]["wall_ms"] > end:
        problems.append("Native observation does not conservatively cover the benchmark interval")
    wall_elapsed = result["end"]["wall_ms"] - result["start"]["wall_ms"]
    monotonic_elapsed = result["end"]["monotonic_ms"] - result["start"]["monotonic_ms"]
    if abs(wall_elapsed - monotonic_elapsed) > 100:
        problems.append("Page wall and monotonic clocks diverged")
    return {"run": report["run"], "score": mean, "iteration_scores": values,
            "completion_after_focused_iframe_cleanup": cleanup_focus_boundary,
            "elapsed_seconds": monotonic_elapsed / 1000, "condition_problems": sorted(set(problems)),
            "conditions_consistent": not problems, "native_environment": context,
            "viewport": {k: result["start"][k] for k in ("width", "height", "device_pixel_ratio")}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--runs", nargs="+", default=["control-1", "alpha-1", "alpha-2", "control-2"])
    args = parser.parse_args()
    rows, reports = [], []
    for run in args.runs:
        report = json.loads((args.directory / (run + ".json")).read_text())
        environment = [json.loads(line) for line in (args.directory / (run + "-environment.jsonl")).read_text().splitlines()]
        reports.append(report)
        rows.append(inspect_run(report, environment))
    comparable = all(row["conditions_consistent"] for row in rows)
    first = reports[0]
    comparable &= all(r["assets"] == first["assets"] and r["fixture_sha256"] == first["fixture_sha256"]
                      and r["result"]["user_agent"] == first["result"]["user_agent"] for r in reports)
    comparable &= all(row["viewport"] == rows[0]["viewport"] for row in rows)
    groups = {kind: [row["score"] for row in rows if row["run"].startswith(kind + "-")]
              for kind in ("alpha", "control")}
    comparable &= all(len(values) >= 2 and all(v is not None for v in values) for values in groups.values())
    comparison = None
    if comparable:
        alpha, control = statistics.mean(groups["alpha"]), statistics.mean(groups["control"])
        comparison = {"alpha_mean": alpha, "control_mean": control,
                      "alpha_score_change_percent": (alpha / control - 1) * 100,
                      "higher_score_is_better": True}
    print(json.dumps({"scope": "paired_speedometer_development_baseline", "runs": rows,
                      "observed_conditions_comparable": bool(comparable), "comparison": comparison,
                      "benchmark_qualified": False, "milestone_0_qualified": False,
                      "limits": ["Small development-machine sample, not a release workload or confidence-bound acceptance",
                                 "Fresh profiles omit required extensions; extension compatibility is user-accepted separately",
                                 "Desktop background applications remain running; accessibility used before each run",
                                 "Does not measure startup, switching, memory, or blocker request latency"]}, indent=2))


if __name__ == "__main__":
    main()
