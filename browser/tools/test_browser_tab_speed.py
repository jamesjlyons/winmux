#!/usr/bin/env python3
"""Benchmark signed Chromium creation in a fresh, isolated authenticated service.

Uses the real XPC creation/layout/focus APIs and native keyboard acknowledgements.
No installed app, existing workspace, or user profile is changed. This fixture
does not include WinMux's full native discovery/sidebar rendering pipeline.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import threading
import time
import uuid
import zlib

from measure_helper import Sampler
from test_browser_switch_speed import require_unlocked_session
from test_browser_layout_watchdog import require_free_native_lease

ROOT = Path(__file__).resolve().parents[2]
BROWSER_ID = "com.jameslyons.winmux.browser.alpha"


def summary(values):
    values = sorted(values)
    if not values:
        return None
    return {"samples": len(values), "median_ms": (values[(len(values) - 1) // 2] + values[len(values) // 2]) / 2,
            "p95_ms": values[math.ceil(len(values) * .95) - 1]}


def timings(path):
    events = {}
    for line in path.read_text(errors="replace").splitlines():
        if "WINMUX_TAB_TIMING " not in line:
            continue
        try:
            event = json.loads(line.split("WINMUX_TAB_TIMING ", 1)[1])
            events.setdefault(event["operation"], {}).setdefault(event["stage"], event["time_us"])
        except (ValueError, KeyError):
            continue
    return events


def evaluate(samples, events):
    result = {}
    for kind in ("blank", "cached_url"):
        rows = [r for r in samples if r["kind"] == kind]
        def elapsed(field):
            return [(r[field] - r["command_us"]) / 1000 for r in rows if r.get(field) is not None]
        presented = [(events[r["operation"]]["presented"] - r["command_us"]) / 1000
                     for r in rows if "presented" in events.get(r["operation"], {})]
        icons = [(r["favicon_observed_us"] - r["inventory_us"]) / 1000 for r in rows
                 if r.get("favicon_observed_us") is not None]
        if any(v < 0 for field in ("input_ack_us", "inventory_us", "layout_us") for v in elapsed(field)) or any(v < 0 for v in presented):
            raise ValueError("Non-monotonic creation timings")
        # An icon can already exist in the first creation inventory.
        result[kind] = {"input": summary(elapsed("input_ack_us")),
                        "inventory": summary(elapsed("inventory_us")),
                        "layout": summary(elapsed("layout_us")),
                        "presentation": summary(presented),
                        "favicon_after_inventory": summary([max(0, v) for v in icons]),
                        "warm_hits": sum("warm_window_ready" in events.get(r["operation"], {}) for r in rows)}
    return result


def targets_met(metrics, samples):
    cached = metrics["cached_url"]
    def usable(kind):
        row = metrics[kind]
        return (row["input"] is not None and row["input"]["samples"] == samples and
                row["input"]["p95_ms"] <= 100 and row["presentation"] is not None and
                row["presentation"]["samples"] == samples and row["presentation"]["p95_ms"] <= 100 and
                row["warm_hits"] >= math.ceil(samples * .95))
    return (all(usable(kind) for kind in ("blank", "cached_url")) and
            cached["favicon_after_inventory"] is not None and
            cached["favicon_after_inventory"]["samples"] == samples and
            cached["favicon_after_inventory"]["p95_ms"] <= 50)


def png():
    def chunk(name, data):
        return struct.pack("!I", len(data)) + name + data + struct.pack("!I", zlib.crc32(name + data))
    pixels = b"".join(b"\0" + bytes((30, 120, 220, 255)) * 16 for _ in range(16))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 16, 16, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        icon = self.path == "/favicon.png"
        if not icon:
            time.sleep(.15)  # Verify cached icons don't wait for page HTML.
        body = png() if icon else b'<!doctype html><link rel="icon" href="/favicon.png"><title>Local tab fixture</title><p>Fixture</p>'
        self.send_response(200)
        self.send_header("Content-Type", "image/png" if icon else "text/html")
        self.send_header("Cache-Control", "max-age=3600" if icon else "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def process_resources(browser_pid, executable):
    """Sum per-process footprints for only this browser and its descendants."""
    parents = {int(pid): int(ppid) for pid, ppid in
               (line.split() for line in subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True).splitlines())}
    descendants = {browser_pid}
    while True:
        found = {pid for pid, parent in parents.items() if parent in descendants}
        if found <= descendants:
            break
        descendants |= found
    result = {}
    for pid in descendants:
        try:
            # proc_pidpath is scoped to an already-known descendant PID.
            sampler = Sampler(browser_pid, executable)
            import ctypes
            path = ctypes.create_string_buffer(4096)
            if sampler.proc.proc_pidpath(pid, path, len(path)) > 0:
                result[pid] = Sampler(pid, Path(os.fsdecode(path.value))).read()
        except OSError:
            pass  # A renderer may finish between the tree and rusage reads.
    return result


def run(app, manifest, directory, samples, helper_override, disable_warming, keep_last=False):
    directory.mkdir(parents=True, exist_ok=False)
    executable = app / "Contents/MacOS/Chromium"
    helper = app / manifest["helper_relative_path"]
    identity = manifest["identity_sha1"]
    if helper_override:
        # Keep the embedded app metadata/resources and executable-relative
        # loader paths when using a new helper with an archived browser.
        source_helper_app = helper.parents[2]
        if source_helper_app.suffix != ".app" or not (source_helper_app / "Contents/Info.plist").is_file():
            raise RuntimeError("Baseline helper must have an embedded application bundle")
        helper_app = directory / "WinMux Workspace.app"
        subprocess.run(["cp", "-cpR", str(source_helper_app), str(helper_app)], check=True)
        helper = helper_app / "Contents/MacOS/WinMuxWorkspaceHelper"
        shutil.copy2(helper_override, helper)
        subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", BROWSER_ID + ".workspace",
                        "--options", "runtime", "--timestamp=none", str(helper_app)], check=True)
    probe_app = directory / "Tab Input Probe.app"
    probe = probe_app / "Contents/MacOS/tab-input-probe"
    probe.parent.mkdir(parents=True)
    (probe_app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": BROWSER_ID + ".workspace", "CFBundleName": "Tab Input Probe",
        "CFBundleExecutable": probe.name, "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "LSUIElement": True, "NSHighResolutionCapable": True,
    }))
    subprocess.run(["swiftc", "-O", "-module-cache-path", str(directory / "module-cache"),
                    str(ROOT / "browser/tools/tab_input_probe.swift"), "-o", str(probe)], check=True)
    subprocess.run(["codesign", "--force", "--sign", identity, "--identifier", BROWSER_ID + ".workspace",
                    "--options", "runtime", "--timestamp=none", str(probe_app)], check=True)
    service = BROWSER_ID + ".workspace.test." + str(uuid.uuid4())
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    report = directory / "helper.json"
    plist = directory / "helper.plist"
    plist.write_bytes(plistlib.dumps({"Label": service, "ProgramArguments": [str(helper), service, str(report)],
        "MachServices": {service: True}, "RunAtLoad": True, "ProcessType": "Interactive",
        "EnvironmentVariables": {"WINMUX_TRACE_TABS": "1", "WINMUX_TAB_SPEED_SAMPLES": str(samples),
            "WINMUX_TAB_SPEED_KEEP_LAST": "1" if keep_last else "0",
            "WINMUX_TAB_SPEED_PROBE": str(probe), "WINMUX_TAB_SPEED_URL": f"http://127.0.0.1:{server.server_port}/cached"},
        "StandardOutPath": str(directory / "helper.log"), "StandardErrorPath": str(directory / "helper.log")}))
    browser = None
    result = {"passed": False, "samples": [], "helper_override_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(),
              "fixture_scope": "authenticated_creation_layout_focus; native_keyboard; excludes_full_winmux_sidebar"}
    try:
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True, timeout=10)
        command = [str(executable), "--user-data-dir=" + str(directory / "profile"), "--no-first-run",
                   "--no-default-browser-check", "--disable-background-networking",
                   "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
                   "--enable-logging=stderr", "--winmux-trace-tabs", "--winmux-sidebar-preview",
                   "--winmux-bridge-report=" + str(directory / "bridge.json"),
                   "--winmux-test-inventory-actions", "--winmux-test-service=" + service,
                   "about:blank"]
        if disable_warming:
            command.append("--winmux-disable-tab-warming")
        with (directory / "browser.log").open("x") as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 120 + samples * 3
            while time.monotonic() < deadline:
                if browser.poll() is not None:
                    raise RuntimeError("Fixture browser exited")
                if report.exists():
                    state = json.loads(report.read_text())
                    outcome = state["outcomes"].get("tab_speed")
                    if outcome:
                        if outcome != "complete":
                            raise RuntimeError("Tab fixture failed: " + outcome)
                        result["samples"] = state["tab_speed_samples"]
                        break
                time.sleep(.2)
            else:
                raise TimeoutError("Tab fixture did not complete")
            result["metrics"] = evaluate(result["samples"], timings(directory / "browser.log"))
            # Chromium can reap the renderer of the just-closed measured tab.
            # Sample idle resources after this ordinary lifecycle work settles.
            time.sleep(5)
            for settling_intervals in range(3):
                before = process_resources(browser.pid, executable)
                time.sleep(10)
                after = process_resources(browser.pid, executable)
                if set(before) == set(after):
                    break
            else:
                raise RuntimeError("Browser process tree did not settle for idle sampling")
            result["resources"] = {"summed_process_footprint_bytes": sum(r["physical_footprint_bytes"] for r in after.values()),
                "idle_cpu_one_core_percent": sum(after[p]["cpu_ns"] - before[p]["cpu_ns"] for p in before) / 1e8,
                "processes": len(after), "settling_intervals_discarded": settling_intervals}
            result["passed"] = len(result["samples"]) == samples * 2
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        if browser and browser.poll() is None:
            browser.terminate()
            try:
                browser.wait(timeout=10)
            except subprocess.TimeoutExpired:
                browser.kill(); browser.wait(timeout=10)
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{service}"], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        server.shutdown(); server.server_close()
        (directory / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=100)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--helper-override", type=Path, help="Current helper for a baseline engine; copied/signed only inside the fixture")
    parser.add_argument("--disable-warming", action="store_true")
    parser.add_argument("--require-targets", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.samples <= 1000 or not 1 <= args.runs <= 10:
        parser.error("samples must be 1–1000 and runs 1–10")
    app = args.app.resolve(strict=True)
    manifest = json.loads((app.parent / "winmux-package-manifest.json").read_text())
    if manifest.get("verified") is not True or not re.fullmatch(r"[A-Z0-9]{10}", manifest.get("team_identifier", "")):
        parser.error("A verified signed package is required")
    for path, expected, identifier in [(app / "Contents/MacOS/Chromium", manifest["browser_executable_sha256"], BROWSER_ID),
                                        (app / manifest["helper_relative_path"], manifest["helper_sha256"], BROWSER_ID + ".workspace")]:
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            parser.error("Packaged executable changed")
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{manifest["team_identifier"]}"'
        subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(app if identifier == BROWSER_ID else path)], check=True)
    output = args.output.resolve()
    require_unlocked_session()
    require_free_native_lease()
    output.mkdir(parents=True, exist_ok=False)
    runs = [run(app, manifest, output / f"run-{i + 1}", args.samples,
                args.helper_override.resolve(strict=True) if args.helper_override else None, args.disable_warming)
            for i in range(args.runs)]
    result = {"passed": all(r["passed"] for r in runs), "runs": runs,
              "package_manifest_sha256": hashlib.sha256((app.parent / "winmux-package-manifest.json").read_bytes()).hexdigest(),
              "limitations": ["Local synthetic URLs; no extension workload or remote network latency.",
                "Input uses process-scoped native events and AX acknowledgement; sampling/transport overhead is included.",
                "Browser footprints are sums of process accounting, not unique physical pages.",
                "Favicon timing ends at helper inventory, not a rendered sidebar icon.",
                "Presentation is available only from instrumented Chromium; missing callbacks cannot qualify the target."]}
    if args.require_targets:
        result["passed"] &= all(targets_met(r["metrics"], args.samples) for r in runs)
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"passed": result["passed"], "metrics": [r["metrics"] for r in runs]}, indent=2))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
