#!/usr/bin/env python3
"""Read-only macOS helper CPU/physical-footprint sampling; never qualifies M0.

Requires an already running helper and its verified package manifest. Does not
launch apps, send XPC messages, inspect profiles or collect process arguments.
CPU totals from proc_pid_rusage are Mach ticks, including on Apple Silicon;
convert them using mach_timebase_info, not an assumed nanosecond timebase.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import time


class RUsageV0(ctypes.Structure):
    # Layout from the macOS SDK sys/resource.h, RUSAGE_INFO_V0.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "package_wakeups", "interrupt_wakeups", "pageins",
            "wired", "resident", "footprint", "start", "exit")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class Sampler:
    def __init__(self, pid, executable):
        if platform.system() != "Darwin":
            raise RuntimeError("This collector requires macOS")
        self.pid = pid
        self.executable = str(executable.resolve(strict=True))
        self.proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.proc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.proc.proc_pid_rusage.restype = ctypes.c_int
        self.proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.proc.proc_pidpath.restype = ctypes.c_int
        self.system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        self.system.mach_timebase_info.restype = ctypes.c_int
        for name in ("mach_absolute_time", "mach_continuous_time"):
            getattr(self.system, name).argtypes = []
            getattr(self.system, name).restype = ctypes.c_uint64
        self.timebase = Timebase()
        if self.system.mach_timebase_info(ctypes.byref(self.timebase)) or not self.timebase.denom:
            raise RuntimeError("Cannot read Mach clock timebase")

    def ns(self, ticks):
        return ticks * self.timebase.numer // self.timebase.denom

    def read(self):
        info = RUsageV0()
        if self.proc.proc_pid_rusage(self.pid, 0, ctypes.byref(info)):
            raise OSError(ctypes.get_errno(), "Cannot sample helper")
        path = ctypes.create_string_buffer(4096)
        if self.proc.proc_pidpath(self.pid, path, len(path)) <= 0:
            raise OSError(ctypes.get_errno(), "Cannot verify helper executable")
        if os.fsdecode(path.value) != self.executable or info.exit:
            raise RuntimeError("Helper exited or executable identity changed")
        return {"continuous_ns": self.ns(self.system.mach_continuous_time()),
                "awake_ns": self.ns(self.system.mach_absolute_time()),
                "cpu_ns": self.ns(info.user + info.system),
                "physical_footprint_bytes": info.footprint,
                "resident_bytes": info.resident,
                "process_start_ticks": info.start,
                "executable_uuid": bytes(info.uuid).hex()}


def summarize(samples, duration_seconds, interval_seconds):
    """Reject broken series, rather than averaging restarts or sleep into idle CPU."""
    problems = []
    metrics = {}
    if len(samples) < 2:
        return {"valid_series": False, "problems": ["Fewer than two samples"], "metrics": {}}
    first, last = samples[0], samples[-1]
    identity = (first["process_start_ticks"], first["executable_uuid"])
    for item in samples:
        if (item["process_start_ticks"], item["executable_uuid"]) != identity:
            problems.append("Process restarted or PID was reused")
    for a, b in zip(samples, samples[1:]):
        continuous = b["continuous_ns"] - a["continuous_ns"]
        awake = b["awake_ns"] - a["awake_ns"]
        if continuous <= 0 or awake <= 0 or b["cpu_ns"] < a["cpu_ns"]:
            problems.append("Non-monotonic clock or CPU counter")
        if abs(continuous - awake) > 100_000_000:
            problems.append("System sleep interrupted the sample window")
        if continuous > (interval_seconds + max(1, interval_seconds * .2)) * 1e9:
            problems.append("Sampling gap exceeded the allowed interval")
    elapsed = (last["continuous_ns"] - first["continuous_ns"]) / 1e9
    if elapsed < duration_seconds:
        problems.append("Incomplete observation window")
    if not problems:
        cpu = last["cpu_ns"] - first["cpu_ns"]
        metrics = {"elapsed_seconds": elapsed, "cpu_seconds": cpu / 1e9,
                   "average_cpu_percent_one_core": cpu / (elapsed * 1e9) * 100,
                   "sampled_max_physical_footprint_bytes": max(s["physical_footprint_bytes"] for s in samples),
                   "sampled_min_physical_footprint_bytes": min(s["physical_footprint_bytes"] for s in samples)}
    return {"valid_series": not problems, "problems": sorted(set(problems)), "metrics": metrics}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("Expected a finite positive number")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--package-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=positive, default=300)
    parser.add_argument("--interval", type=positive, default=5)
    parser.add_argument("--settle-seconds", type=positive, default=30)
    args = parser.parse_args()
    if args.pid <= 0 or args.interval > min(30, args.seconds):
        parser.error("Use a positive PID and an interval no larger than 30 seconds or the duration")
    manifest = json.loads(args.package_manifest.read_text())
    executable_hash = sha256(args.executable)
    if manifest.get("verified") is not True or manifest.get("helper_sha256") != executable_hash:
        parser.error("Helper does not match a verified package manifest")
    collector = Sampler(args.pid, args.executable)
    report = {"scope": "preliminary_single_helper_resource_observation",
              "milestone_0_qualified": False, "workspace_workload_qualified": False,
              "workload": "Existing transport helper, no window management or injected load",
              "recorded_utc": datetime.now(timezone.utc).isoformat(),
              "pid": args.pid, "executable": collector.executable,
              "executable_sha256": executable_hash,
              "package_manifest_sha256": sha256(args.package_manifest),
              "collector_sha256": sha256(Path(__file__)),
              "hardware": {"model": subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                           "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
                           "os": platform.mac_ver()[0], "architecture": platform.machine()},
              "mach_timebase": {"numer": collector.timebase.numer, "denom": collector.timebase.denom},
              "requested_seconds": args.seconds, "interval_seconds": args.interval,
              "settle_seconds": args.settle_seconds,
              "limits": ["One process only; no browser tree or control comparison",
                         "No extension, startup, input, presentation or energy qualification",
                         "Footprint is sampled, not the lifetime peak; hardware is the 16 GiB development Mac",
                         "Settling waits without injecting work; it does not prove workload inactivity"],
              "samples": []}
    # Exclusive creation preserves prior evidence even if invocation is repeated.
    with args.output.open("x") as output:
        json.dump(report, output, indent=2)
        output.flush()
        try:
            identity = collector.read()
            for _ in range(math.ceil(args.settle_seconds / 30)):
                time.sleep(min(30, args.settle_seconds - _ * 30))
            first = collector.read()
            if (first["process_start_ticks"], first["executable_uuid"]) != (
                    identity["process_start_ticks"], identity["executable_uuid"]):
                raise RuntimeError("Helper restarted while settling")
            report["samples"].append(first)
            deadline = first["continuous_ns"] + int(args.seconds * 1e9)
            while report["samples"][-1]["continuous_ns"] < deadline:
                remaining = (deadline - report["samples"][-1]["continuous_ns"]) / 1e9
                time.sleep(min(args.interval, remaining))
                report["samples"].append(collector.read())
        except (OSError, RuntimeError, KeyboardInterrupt) as error:
            report["collection_error"] = str(error) or type(error).__name__
        report.update(summarize(report["samples"], args.seconds, args.interval))
        if "collection_error" in report:
            report.update(valid_series=False, metrics={})
            report["problems"].append(report["collection_error"])
        if sha256(args.executable) != executable_hash:
            report.update(valid_series=False, metrics={})
            report["problems"].append("Executable changed during observation")
        output.seek(0)
        output.truncate()
        json.dump(report, output, indent=2)
        output.write("\n")
    print(json.dumps({key: report[key] for key in ("scope", "valid_series", "metrics", "problems")}, indent=2))
    return 0 if report["valid_series"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
