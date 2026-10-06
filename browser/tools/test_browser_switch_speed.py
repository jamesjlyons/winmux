#!/usr/bin/env python3
"""Live pinned-desktop switching in a fresh signed browser and isolated workspace.

Measures command -> trusted destination keyboard acknowledgement and two animation
callbacks. These are observation upper bounds, not compositor presentation traces.
Requires an unowned native-management lease; never stops an existing workspace.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import selectors
import subprocess
import time
import uuid

from switch_page_fixture import SwitchPages
from check_environment import evaluate as evaluate_environment
from test_browser_layout_watchdog import (
    BROWSER_ID, ROOT, browser_rows, require_free_native_lease, request,
    stop_process, wait_for_workspace_socket,
)


def wait_until(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.025)
    raise TimeoutError("Fixture state did not become ready")


def statistics(values):
    ordered = sorted(values)
    count = len(ordered)
    return dict(count=count, median_ms=(ordered[(count-1)//2] + ordered[count//2]) / 2,
                p95_ms=ordered[math.ceil(count*.95)-1], p99_ms=ordered[math.ceil(count*.99)-1],
                max_ms=ordered[-1]) if ordered else None


def console_session_unlocked(registry, uid):
    roots = [registry] if isinstance(registry, dict) else registry
    return any(session.get("kCGSSessionUserIDKey") == uid
               and session.get("kCGSSessionOnConsoleKey") is True
               # macOS omits the lock key after unlocking the console.
               and session.get("CGSSessionScreenIsLocked", False) is False
               for root in roots if isinstance(root, dict)
               for session in root.get("IOConsoleUsers", []) if isinstance(session, dict))


def require_unlocked_session():
    registry = plistlib.loads(subprocess.check_output(
        ["/usr/sbin/ioreg", "-n", "Root", "-d", "1", "-a"], timeout=5))
    if not console_session_unlocked(registry, os.getuid()):
        raise RuntimeError("Unlock the current macOS console session before live window verification")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=60)
    parser.add_argument("--pages", type=int, default=35)
    parser.add_argument("--skip-freeze", action="store_true", help="Warm-path diagnostic only")
    parser.add_argument("--failure-hold-seconds", type=int, default=0,
                        help="Keep a failed isolated fixture open briefly for UI diagnosis")
    args = parser.parse_args()
    if args.samples < 2 or not 15 <= args.pages <= 64:
        parser.error("Use at least two samples and 15–64 fixture pages")
    if not 0 <= args.failure_hold_seconds <= 120:
        parser.error("Failure hold must be between zero and 120 seconds")
    app = args.app.resolve(strict=True)
    manifest_path = app.parent / "winmux-package-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    team = manifest.get("team_identifier", "")
    if manifest.get("verified") is not True or not re.fullmatch(r"[A-Z0-9]{10}", team):
        parser.error("A verified signed package is required")
    executable = app / "Contents/MacOS/Chromium"
    helper = app / manifest["helper_relative_path"]
    for path, binary, identifier, key in [
        (app, executable, BROWSER_ID, "browser_executable_sha256"),
        (helper, helper, BROWSER_ID + ".workspace", "helper_sha256"),
    ]:
        if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest[key]:
            parser.error("Packaged executable changed")
        requirement = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "="+requirement, str(path)], check=True)
    require_unlocked_session()
    require_free_native_lease()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture_app = output / "Native Fixture.app/Contents"
    (fixture_app / "MacOS").mkdir(parents=True)
    native_binary = fixture_app / "MacOS/NativeWindowFixture"
    (fixture_app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.jameslyons.winmux.fixture." + str(uuid.uuid4()),
        "CFBundleExecutable": native_binary.name, "CFBundleName": "WinMux Speed Fixture",
        "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication",
    }))
    input_binary = output / "input-probe"
    for source, binary in [("native_window_fixture.swift", native_binary), ("switch_input_probe.swift", input_binary)]:
        subprocess.run(["swiftc", "-O", "-module-cache-path", str(output / "module-cache"),
                        str(ROOT / "browser/tools" / source), "-o", str(binary)], check=True)
    environment_binary = output / "observe-environment"
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-swift-version", "6",
                    "-module-cache-path", str(output / "module-cache"),
                    str(ROOT / "browser/tools/observe_environment.swift"),
                    "-o", str(environment_binary)], check=True)
    # Same local development identity; this probe only posts F13 to its one PID.
    subprocess.run(["codesign", "--force", "--sign", manifest["identity_sha1"],
                    "--identifier", BROWSER_ID + ".workspace", "--timestamp=none", str(input_binary)], check=True)
    service = BROWSER_ID + ".workspace.test." + str(uuid.uuid4())
    native_state = output / "native-state"
    native_state.mkdir(mode=0o700)
    (native_state / "winmux-browser-state-v1").write_text("isolated-browser-workspace\n")
    (native_state / "winmux.toml").write_text("""config-version = 2
start-at-login = false
auto-reload-config = false
persistent-workspaces = []
workspace-interaction-mode = 'views'
shortcuts-preset = 'none'
automatically-unhide-macos-hidden-apps = false
[workspace-sidebar]
enabled = true
always-expanded = false
chrome-style = 'solid'
solid-chrome-color = 'system'
[workspace-sidebar.project-labels]
speed-space = 'Speed fixture'
[mode.main.binding]
""")
    digest = hashlib.sha256(str(native_state).encode()).hexdigest()[:24]
    endpoint = Path(f"/tmp/winmux-browser-{os.getuid()}-{digest}.sock")
    result = dict(scope="isolated_live_pinned_desktop_switching", passed=False, samples=[],
                  requested_warm_samples=args.samples, requested_space_samples=args.samples,
                  fixture_page_count=args.pages, freeze_check_requested=not args.skip_freeze,
                  package_manifest_sha256=hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
                  probe_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  fixture_sha256=hashlib.sha256((ROOT / "browser/tools/switch_page_fixture.py").read_bytes()).hexdigest(),
                  daily_driver_qualified=False,
                  limits=["Fresh local synthetic pages; no extensions or remote network load.",
                          "Start is immediately before the local workspace command; receipt times are observation upper bounds including probe transport.",
                          "After command acknowledgement, scoped F13 probes repeat at 5 ms intervals until the intended page responds; this sampling overhead is included.",
                          "Trusted keyboard event acknowledgement proves the destination handled input; two animation callbacks are not compositor presentation evidence.",
                          "Small sequential sample; does not qualify the full approved interaction workload."])
    pages = SwitchPages(args.pages)
    browser = fixture = input_probe = awake = environment = None
    environment_path = output / "environment.jsonl"
    environment_done = output / "measurement-complete"
    bootstrapped = False
    input_ready = selectors.DefaultSelector()
    try:
        with (output / "fixture.log").open("x") as log:
            fixture = subprocess.Popen([str(native_binary), str(output / "fixture.json")], stdout=log, stderr=subprocess.STDOUT)
        wait_until(lambda: (output / "fixture.json").exists())
        plist = output / "test-helper.plist"
        plist.write_bytes(plistlib.dumps({"Label": service, "ProgramArguments": [str(helper), service,
            str(output / "helper.json"), "--manage-native", str(native_state), "--native-process", str(fixture.pid)],
            "MachServices": {service: True}, "RunAtLoad": True, "ProcessType": "Interactive",
            "StandardOutPath": str(output / "helper.log"), "StandardErrorPath": str(output / "helper.log")}))
        bootstrapped = True
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True, timeout=10)
        wait_for_workspace_socket(endpoint)

        def rows():
            data = json.loads(request(endpoint, ["surface", "list"]))
            fixture_ids = {w["window_id"] for w in json.loads((output / "fixture.json").read_text())["windows"]}
            if not {r["nativeWindowID"] for r in data if r.get("nativeWindowID")} <= fixture_ids:
                raise RuntimeError("Native discovery escaped its fixture process")
            return data

        def native_rows():
            current = [r for r in rows() if r.get("nativeWindowID")]
            return current if len(current) == 2 else None
        natives = wait_until(native_rows)
        for i, row in enumerate(natives):
            request(endpoint, ["surface", "move", row["id"], f"Native-{i}"])
        request(endpoint, ["surface", "pin", natives[0]["id"]])
        result["native_pin"] = next(r for r in rows() if r["id"] == natives[0]["id"])
        if not result["native_pin"].get("pinnedDesktopID"):
            raise RuntimeError("Native pin did not acquire its dedicated desktop")
        command = [str(executable), "--user-data-dir=" + str(output / "profile"),
                   "--no-first-run", "--no-default-browser-check", "--enable-logging=stderr",
                   "--winmux-sidebar-preview", "--winmux-test-service=" + service,
                   "--winmux-bridge-report=" + str(output / "bridge.json"), *pages.urls]
        result["command"] = command
        with (output / "browser.log").open("x") as log:
            browser = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        awake = subprocess.Popen(["caffeinate", "-di", "-w", str(browser.pid)])
        tabs = wait_until(lambda: (t if len(t := browser_rows(rows())) == args.pages else None), timeout=40)
        ids = [t["id"] for t in tabs]
        for i, surface in enumerate(ids):
            request(endpoint, ["surface", "move", surface, f"Page-{i}"])
        input_probe = subprocess.Popen([str(input_binary), str(browser.pid)], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, text=True, bufsize=1)
        input_ready.register(input_probe.stdout, selectors.EVENT_READ)

        def key():
            input_probe.stdin.write("probe\n"); input_probe.stdin.flush()
            if not input_ready.select(3) or input_probe.stdout.readline().strip() != "posted":
                raise RuntimeError("Scoped keyboard input probe is unavailable")

        mapping = {}
        result["initial_focus_retries"] = 0
        # A trusted input acknowledgement from each distinct page establishes
        # that every destination has loaded. A one-shot startup fetch can be
        # cancelled while Chromium attaches that page to its singleton host.
        print(json.dumps(dict(phase="mapping_keyboard_targets", pages=len(ids))), flush=True)
        for surface in ids:
            request(endpoint, ["surface", "focus", surface])
            wait_until(lambda: next((r for r in rows() if r["id"] == surface and r["browser"].get("requestedVisible")
                                    and r["browser"].get("layoutReply") == "issued"), None))
            time.sleep(.15)
            start = time.perf_counter_ns()
            deadline = time.monotonic() + 5
            while True:
                key()
                try:
                    event = pages.wait("input", start, timeout=.05)
                    break
                except TimeoutError:
                    if time.monotonic() >= deadline:
                        result["mapping_failure"] = dict(surface=surface,
                            inventory=next(r for r in rows() if r["id"] == surface))
                        raise TimeoutError("Selected fixture page did not acknowledge keyboard input") from None
                    # Startup can still be attaching the renderer to its new
                    # singleton host. This preparation is outside all samples;
                    # measured switches below issue exactly one focus command.
                    request(endpoint, ["surface", "focus", surface])
                    result["initial_focus_retries"] += 1
            if not event["visible"] or not event["focused"]:
                raise RuntimeError("Initial fixture keyboard focus is incorrect")
            mapping[surface] = event["page"]
        if len(set(mapping.values())) != len(ids):
            raise RuntimeError("Fixture page identities are not distinct")
        result["page_mapping"] = mapping
        pages.wait("protected_lock", 0, page=0)
        request(endpoint, ["surface", "focus", natives[0]["id"]])
        time.sleep(.2)
        start = time.perf_counter_ns()
        request(endpoint, ["surface", "focus", ids[-1]])
        deadline = time.monotonic() + 2
        while True:
            key()
            try:
                returned = pages.wait("input", start, page=mapping[ids[-1]], timeout=.005)
                break
            except TimeoutError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Browser did not regain keyboard focus from the native fixture") from None
        result["native_to_browser_focus_verified"] = returned["visible"] and returned["focused"]
        if not result["native_to_browser_focus_verified"]:
            raise RuntimeError("Returning from the native fixture left the page unfocused")
        # A pin receives its own desktop. Pinning an existing split keeps both
        # members together, with their native host identities unchanged.
        warm_peer, first, second, peer = ids[-4:]
        # A fresh helper may initially select the configured second Space.
        # Assign both destinations explicitly instead of assuming launch chose
        # Space 1; distinct desktop IDs alone do not imply distinct Spaces.
        for surface in [first, warm_peer]:
            request(endpoint, ["surface", "focus", surface])
            request(endpoint, ["move-node-to-project", "1", "--focus-follows-window"])
        request(endpoint, ["surface", "pin", first])
        request(endpoint, ["surface", "pin", warm_peer])
        for surface in [second, peer]:
            request(endpoint, ["surface", "focus", surface])
            request(endpoint, ["move-node-to-project", "2", "--focus-follows-window"])
        request(endpoint, ["surface", "group", second, peer, "horizontal"])
        request(endpoint, ["surface", "pin", second])
        pinned = {r["id"]: r for r in rows() if r["id"] in [first, second, peer]}
        if not (pinned[first].get("pinnedDesktopID") and pinned[second].get("pinnedDesktopID")
                and pinned[second]["pinnedDesktopID"] == pinned[peer].get("pinnedDesktopID")
                and pinned[first]["workspace"] != pinned[second]["workspace"]):
            raise RuntimeError("Pinning did not preserve dedicated/group desktop ownership")
        result["pins"] = pinned
        with (output / "environment.log").open("x") as log:
            environment = subprocess.Popen([str(environment_binary), "--pid", str(browser.pid),
                "--executable", str(executable), "--output", str(environment_path),
                "--seconds", "600", "--interval", "1", "--until-file", str(environment_done)],
                stdout=log, stderr=subprocess.STDOUT)
        wait_until(lambda: environment_path.exists() and len(environment_path.read_text().splitlines()) >= 2)
        print(json.dumps(dict(phase="warm", samples=args.samples)), flush=True)

        def measure(surface, kind, command=None):
            before = next(r for r in rows() if r["id"] == surface)
            expected = "frozen" if kind == "frozen" else "background"
            settling_start = time.perf_counter_ns()
            settling_wait_ms = 0
            if expected == "background" and before["browser"]["lifecycle"] == "active":
                # Inventory delivery can lag the preceding switch's renderer
                # acknowledgement. Establish the next sample's background
                # precondition before starting its clock, and record the wait.
                try:
                    before = wait_until(lambda: next((r for r in rows() if r["id"] == surface
                        and r["browser"]["lifecycle"] == expected), None), timeout=2)
                    settling_wait_ms = (time.perf_counter_ns() - settling_start) / 1e6
                except TimeoutError:
                    result["switch_failure"] = dict(kind=kind, target=surface, inventory=rows())
                    raise RuntimeError("Previous switch did not leave the next target in the background") from None
            if before["browser"]["lifecycle"] != expected:
                raise RuntimeError(f"{kind} target is {before['browser']['lifecycle']}, expected {expected}")
            start = time.perf_counter_ns()
            request(endpoint, command or ["surface", "focus", surface])
            reply = time.perf_counter_ns()
            deadline = time.monotonic() + 2
            input_after = start
            transitional_inputs = []
            while True:
                key()
                try:
                    event = pages.wait("input", input_after, page=mapping[surface], timeout=.005)
                    input_after = event["received_ns"] + 1
                    if event["discarded"]:
                        raise RuntimeError("Destination reloaded instead of remaining resident")
                    if event["visible"] and event["focused"]:
                        break
                    # A thawed renderer can accept a queued key before its
                    # visibility notification arrives. Keep the original clock
                    # running until the expected page is actually input-ready.
                    transitional_inputs.append(dict(
                        elapsed_ms=(event["received_ns"]-start)/1e6,
                        visible=event["visible"], focused=event["focused"],
                        input_sequence=event["input_sequence"]))
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Destination did not become visible and focused")
                except TimeoutError:
                    if time.monotonic() >= deadline:
                        result["switch_failure"] = dict(kind=kind, target=surface, inventory=rows())
                        raise TimeoutError("Destination did not acknowledge keyboard input within two seconds") from None
            frames = pages.wait("input_frame_callbacks", event["received_ns"], page=mapping[surface],
                                input_sequence=event["input_sequence"])
            if not event["visible"] or not event["focused"] or event["discarded"]:
                raise RuntimeError("Destination was not visible, focused, and resident")
            result["samples"].append(dict(kind=kind, surface=surface, lifecycle_before=expected,
                input_sequence=event["input_sequence"],
                transitional_input_acknowledgements=transitional_inputs,
                precondition_wait_ms=settling_wait_ms,
                viewport={k: event[k] for k in ["width", "height", "pixel_ratio"]},
                start_ns=start, command_reply_ns=reply, input_received_ns=event["received_ns"],
                animation_callbacks_received_ns=frames["received_ns"],
                command_ms=(reply-start)/1e6, input_upper_bound_ms=(event["received_ns"]-start)/1e6,
                animation_upper_bound_ms=(frames["received_ns"]-start)/1e6))
            time.sleep(.1)

        request(endpoint, ["surface", "focus", warm_peer]); time.sleep(.2)
        for i in range(args.samples):
            measure(first if i % 2 == 0 else warm_peer, "warm")
        request(endpoint, ["surface", "focus", first]); time.sleep(.2)
        request(endpoint, ["surface", "focus", second]); time.sleep(.2)
        print(json.dumps(dict(phase="space", samples=args.samples)), flush=True)
        for i in range(args.samples):
            measure(first if i % 2 == 0 else second, "space", ["project", "1" if i % 2 == 0 else "2"])
        full_widths = [s["viewport"]["width"] for s in result["samples"] if s["kind"] == "space" and s["surface"] == first]
        split_widths = [s["viewport"]["width"] for s in result["samples"] if s["kind"] == "space" and s["surface"] == second]
        if not (min(split_widths) > 0 and max(split_widths) < .6 * min(full_widths)):
            raise RuntimeError("Individual and grouped pins did not receive full and split desktop widths")
        result["dedicated_and_shared_desktop_widths_verified"] = True
        if not args.skip_freeze:
            print(json.dumps(dict(phase="waiting_for_real_freeze", deadline_seconds=190)), flush=True)
            def frozen_pages():
                cold = [r["id"] for r in browser_rows(rows()) if r["browser"]["lifecycle"] == "frozen"]
                return cold if len(cold) >= max(1, args.pages - 15) else None
            cold = wait_until(frozen_pages, timeout=190)
            result["frozen_candidates"] = cold
            protected = next(surface for surface, page in mapping.items() if page == 0)
            if next(r for r in rows() if r["id"] == protected)["browser"]["lifecycle"] in ["frozen", "discarded"]:
                raise RuntimeError("The page holding a web lock lost its freeze protection")
            result["web_lock_protection_retained"] = True
            print(json.dumps(dict(phase="frozen", samples=len(cold))), flush=True)
            for surface in cold:
                measure(surface, "frozen")
        environment_done.touch()
        if environment.wait(timeout=5) != 0:
            raise RuntimeError("Environment observation did not complete")
        result["environment"] = evaluate_environment(
            [json.loads(line) for line in environment_path.read_text().splitlines() if line])
        # Verify unpin changes shelf ownership without moving/closing either pane.
        request(endpoint, ["surface", "unpin", second])
        unpinned = [r for r in rows() if r["id"] in [second, peer]]
        if any(r.get("pinnedDesktopID") or r["workspace"] != pinned[second]["workspace"] for r in unpinned):
            raise RuntimeError("Unpin changed the shared desktop or retained shelf ownership")
        result["unpin_preserved_group"] = True
        # Pin an existing mixed stack as one desktop, retaining the exact native
        # window instead of rebinding to the other window of the same app.
        request(endpoint, ["surface", "unpin", first])
        # Unpin retains the existing desktop's reserved internal identity.
        # Public move commands accept a named destination, so create one for
        # this separate mixed-group scenario after checking unpin preservation.
        first_workspace = "Mixed-fixture"
        request(endpoint, ["surface", "move", first, first_workspace])
        native_peer = natives[1]["id"]
        request(endpoint, ["surface", "move", native_peer, first_workspace])
        request(endpoint, ["surface", "group", first, native_peer, "stack"])
        request(endpoint, ["surface", "pin", first])
        mixed = {r["id"]: r for r in rows() if r["id"] in [first, native_peer]}
        if not (mixed[first].get("pinnedDesktopID") == mixed[native_peer].get("pinnedDesktopID")
                and mixed[first].get("pinnedDesktopID")
                and mixed[native_peer]["nativeWindowID"] == natives[1]["nativeWindowID"]):
            raise RuntimeError("Mixed pin did not preserve its grouped native window")
        result["mixed_pin"] = mixed
        result["passed"] = True
    except (Exception, KeyboardInterrupt) as error:
        result["error"] = f"{type(error).__name__}: {error}"
        if args.failure_hold_seconds and not isinstance(error, KeyboardInterrupt):
            (output / "failure.json").write_text(json.dumps(dict(
                error=result["error"], browser_pid=browser.pid if browser else None,
                mapping_failure=result.get("mapping_failure"), page_events=pages.events), indent=2) + "\n")
            print(json.dumps(dict(phase="failure_diagnostic_hold", seconds=args.failure_hold_seconds)), flush=True)
            try:
                time.sleep(args.failure_hold_seconds)
            except KeyboardInterrupt:
                pass
    finally:
        result["page_events"] = pages.events
        groups = defaultdict(list)
        for sample in result["samples"]:
            groups[sample["kind"]].append(sample)
        result["metrics"] = {kind: {field: statistics([s[field] for s in samples])
                                    for field in ["command_ms", "input_upper_bound_ms", "animation_upper_bound_ms"]}
                             for kind, samples in groups.items()}
        targets = {"warm": 50, "frozen": 100, "space": 150}
        result["input_observation_targets"] = {
            kind: dict(limit_p95_ms=limit, measured=kind in groups,
                       passed=(result["metrics"][kind]["input_upper_bound_ms"]["p95_ms"] <= limit)
                       if kind in groups else None)
            for kind, limit in targets.items()
        }
        result["cleanup"] = {}
        def stop_environment():
            environment_done.touch(exist_ok=True)
            if environment is not None and environment.poll() is None:
                try:
                    environment.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    return stop_process(environment)
            return environment is None or environment.returncode == 0
        for name, action in [
            ("input_selector", input_ready.close), ("input_probe", lambda: stop_process(input_probe)),
            ("environment", stop_environment),
            ("browser", lambda: stop_process(browser)),
            ("sleep_assertion", lambda: stop_process(awake)),
            ("service", lambda: not bootstrapped or subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{service}"], capture_output=True, timeout=10).returncode == 0),
            ("native_fixture", lambda: stop_process(fixture)), ("server", pages.close),
        ]:
            try:
                result["cleanup"][name] = action() is not False
            except Exception as error:
                result["cleanup"][name] = str(error)
        result["passed"] &= all(value is True for value in result["cleanup"].values())
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result.get(k) for k in ["passed", "metrics", "error", "cleanup"]}), flush=True)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
