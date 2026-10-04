import copy
from pathlib import Path
import sys
import subprocess
from unittest import TestCase
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from test_browser_layout_watchdog import cleanup_fixture, require_pending_replacement, require_recovered, require_stable_window_frames, wait_for_workspace_socket


def recovered():
    frame = dict(x=10, y=40, width=800, height=600)
    return [dict(id="browser:fixture", workspace="WatchdogLatest", available=True, selected=True,
                 browser=dict(layoutGeneration=3, layoutTimeoutCount=1, layoutReply="issued",
                              hostWindowID=71, managed=True, requestedVisible=True,
                              requestedFrame=frame, frame=copy.deepcopy(frame)))]


class LayoutWatchdogFixtureTests(TestCase):
    def test_initial_socket_readiness_retries_only_expected_bind_listen_races(self):
        with patch("test_browser_layout_watchdog.request", side_effect=[FileNotFoundError(), ConnectionRefusedError(), "[]"]) as request:
            wait_for_workspace_socket("fixture.sock", sleep=lambda _: None)
        self.assertEqual(request.call_count, 3)
        self.assertTrue(all(call.args == ("fixture.sock", ["surface", "list"]) for call in request.call_args_list))
        for failure in (ConnectionResetError(), TimeoutError(), RuntimeError("command failed")):
            with self.subTest(error=type(failure).__name__), \
                 patch("test_browser_layout_watchdog.request", side_effect=failure) as request, \
                 self.assertRaises(type(failure)):
                wait_for_workspace_socket("fixture.sock")
            self.assertEqual(request.call_count, 1)

    def test_initial_socket_readiness_has_a_deadline(self):
        now = [0.0]
        def sleep(seconds):
            now[0] += seconds
        with patch("test_browser_layout_watchdog.request", side_effect=ConnectionRefusedError()), \
             self.assertRaisesRegex(RuntimeError, "did not become ready"):
            wait_for_workspace_socket("fixture.sock", timeout=.05, clock=lambda: now[0], sleep=sleep)
        self.assertAlmostEqual(now[0], .05)

    def check_geometry_samples(self, frames, result, settling_seconds=3):
        now = [0.0]
        samples = iter(frames)
        def sleep(seconds):
            now[0] += seconds
        require_stable_window_frames(lambda: next(samples), {"71": {"X": 10}}, result, 0,
            settling_seconds=settling_seconds, stable_seconds=.2, clock=lambda: now[0], sleep=sleep)

    def test_geometry_allows_initial_commit_then_requires_full_stable_interval(self):
        result = {}
        self.check_geometry_samples([{}, {"71": {"X": 10}}, {"71": {"X": 10}}, {"71": {"X": 10}}], result)
        self.assertEqual(len(result["settling_window_snapshots"]), 2)
        self.assertEqual(len(result["stable_window_snapshots"]), 3)
        self.assertAlmostEqual(result["matching_geometry_observed_seconds"], .1)
        self.assertGreaterEqual(result["stable_window_snapshots"][-1]["response_seconds"] - .1, .2)

    def test_geometry_drift_after_first_match_fails_without_restarting_settlement(self):
        result = {}
        with self.assertRaisesRegex(AssertionError, "changed after"):
            self.check_geometry_samples([{"71": {"X": 10}}, {"71": {"X": 11}}, {"71": {"X": 10}}], result)
        self.assertEqual(result["stable_window_snapshots"][-1]["frames"], {"71": {"X": 11}})

    def test_geometry_cannot_pass_with_no_match_or_a_match_after_deadline(self):
        for final in ({}, {"71": {"X": 10}}):
            result = {}
            with self.subTest(final=final), self.assertRaisesRegex(AssertionError, "settling deadline"):
                self.check_geometry_samples([{}, {}, {}, final], result, settling_seconds=.25)
            self.assertEqual(len(result["settling_window_snapshots"]), 4)
            self.assertEqual(result["stable_window_snapshots"], [])

    def test_geometry_records_other_process_windows_without_counting_them_as_managed_hosts(self):
        result = {}
        sample = {"71": {"X": 10}, "72": {"X": 9, "Height": 22}}
        self.check_geometry_samples([sample, sample, sample], result)
        for snapshot in result["stable_window_snapshots"]:
            self.assertEqual(snapshot["frames"], {"71": {"X": 10}})
            self.assertEqual(snapshot["other_browser_windows"], {"72": {"X": 9, "Height": 22}})

    def test_other_windows_cannot_substitute_for_missing_or_drifting_original_host(self):
        result = {}
        replacement = {"72": {"X": 10}}
        with self.assertRaisesRegex(AssertionError, "settling deadline"):
            self.check_geometry_samples([replacement] * 4, result, settling_seconds=.25)
        self.assertEqual(result["settling_window_snapshots"][-1]["other_browser_windows"], replacement)
        with self.assertRaisesRegex(AssertionError, "changed after"):
            self.check_geometry_samples([{"71": {"X": 10}}, {"71": {"X": 11}, **replacement}], {})

    def test_cleanup_continues_after_process_error_and_bootout_timeout(self):
        result, ready = {}, Mock()
        observer, browser, fixture = object(), object(), object()
        with patch("test_browser_layout_watchdog.stop_process", side_effect=[OSError("observer failed"), True, True]) as stop, \
             patch("test_browser_layout_watchdog.subprocess.run", side_effect=subprocess.TimeoutExpired("launchctl", 10)) as run:
            self.assertFalse(cleanup_fixture(result, ready, observer, browser, fixture, "isolated.test", True))
        self.assertEqual([call.args[0] for call in stop.call_args_list], [observer, browser, fixture])
        self.assertEqual(run.call_args.kwargs["timeout"], 10)
        self.assertTrue(result["browser_stopped_cleanly"])
        self.assertTrue(result["fixture_stopped_cleanly"])
        self.assertFalse(result["test_service_removed"])
        self.assertEqual(set(result["cleanup_errors"]), {"observer_stopped_cleanly", "test_service_removed"})

    def test_cleanup_continues_after_interruption_and_skips_unstarted_service(self):
        result, ready = {}, Mock()
        ready.close.side_effect = KeyboardInterrupt
        with patch("test_browser_layout_watchdog.stop_process", return_value=True) as stop, \
             patch("test_browser_layout_watchdog.subprocess.run") as run:
            self.assertFalse(cleanup_fixture(result, ready, None, None, None, "isolated.test", False))
        self.assertEqual(stop.call_count, 3)
        run.assert_not_called()
        self.assertTrue(result["test_service_removed"])
        self.assertEqual(set(result["cleanup_errors"]), {"observer_selector_closed"})

    def test_recovered_latest_plan_requires_exact_frame_and_same_native_window(self):
        rows = recovered()
        self.assertEqual(require_recovered(rows, "browser:fixture", "WatchdogLatest", 71, 2),
                         rows[0]["browser"]["frame"])
        for key, value in (("hostWindowID", 72), ("managed", False), ("requestedVisible", False),
                           ("layoutGeneration", 2), ("layoutReply", None),
                           ("pendingLayoutMilliseconds", 4), ("layoutTimeoutCount", 0),
                           ("layoutTimeoutCount", 2), ("requestedFrame", None)):
            rows = recovered()
            rows[0]["browser"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(AssertionError):
                require_recovered(rows, "browser:fixture", "WatchdogLatest", 71, 2)
        rows = recovered()
        rows[0]["browser"]["frame"]["x"] += 1
        with self.assertRaises(AssertionError):
            require_recovered(rows, "browser:fixture", "WatchdogLatest", 71, 2)

    def test_wrong_selection_old_group_and_changed_surface_set_cannot_pass(self):
        for key, value in (("selected", False), ("workspace", "Old"), ("id", "browser:other"), ("available", False)):
            rows = recovered()
            rows[0][key] = value
            with self.subTest(key=key), self.assertRaises(AssertionError):
                require_recovered(rows, "browser:fixture", "WatchdogLatest", 71, 2)
        rows = recovered() * 2
        with self.assertRaises(AssertionError):
            require_recovered(rows, "browser:fixture", "WatchdogLatest", 71, 2)

    def test_replacement_must_be_queued_before_the_dropped_request_times_out(self):
        rows = recovered()
        rows[0]["browser"].update(layoutGeneration=2, layoutTimeoutCount=0,
                                  layoutReply=None, pendingLayoutMilliseconds=130)
        require_pending_replacement(rows, "browser:fixture", "WatchdogLatest", 2)
        for key, value in (("layoutGeneration", 3), ("layoutTimeoutCount", 1),
                           ("layoutReply", "issued"), ("pendingLayoutMilliseconds", None)):
            changed = copy.deepcopy(rows)
            changed[0]["browser"][key] = value
            with self.subTest(key=key), self.assertRaises(AssertionError):
                require_pending_replacement(changed, "browser:fixture", "WatchdogLatest", 2)
