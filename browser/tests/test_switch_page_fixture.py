import http.client
import json
from pathlib import Path
import sys
import time
from unittest import TestCase

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from switch_page_fixture import SwitchPages
from test_browser_switch_speed import console_session_unlocked


class LiveSessionPreflightTests(TestCase):
    def session(self, **overrides):
        return dict(kCGSSessionUserIDKey=501, kCGSSessionOnConsoleKey=True,
                    CGSSessionScreenIsLocked=False) | overrides

    def test_accepts_unlocked_current_console(self):
        self.assertTrue(console_session_unlocked(
            {"IOConsoleUsers": [self.session()]}, 501))

    def test_accepts_unlocked_console_with_absent_lock_key(self):
        session = self.session()
        del session["CGSSessionScreenIsLocked"]
        self.assertTrue(console_session_unlocked({"IOConsoleUsers": [session]}, 501))

    def test_rejects_locked_console(self):
        self.assertFalse(console_session_unlocked(
            {"IOConsoleUsers": [self.session(CGSSessionScreenIsLocked=True)]}, 501))

    def test_another_unlocked_user_does_not_authorize_current_user(self):
        self.assertFalse(console_session_unlocked(
            [{"IOConsoleUsers": [self.session(kCGSSessionUserIDKey=502)]}], 501))

    def test_missing_or_background_console_is_not_ready(self):
        self.assertFalse(console_session_unlocked({}, 501))
        self.assertFalse(console_session_unlocked(
            {"IOConsoleUsers": [self.session(kCGSSessionOnConsoleKey=False)]}, 501))


class SwitchPageFixtureTests(TestCase):
    def setUp(self):
        self.pages = SwitchPages(2)
        self.connection = http.client.HTTPConnection("127.0.0.1", self.pages.server.server_port)

    def tearDown(self):
        self.connection.close()
        self.pages.close()

    def post(self, data, origin=None):
        self.connection.request("POST", f"/{self.pages.token}/event", json.dumps(data),
                                {"Origin": origin or self.pages.origin})
        response = self.connection.getresponse()
        response.read()
        return response.status

    def test_destination_and_start_time_must_match(self):
        self.assertEqual(self.post(dict(page=0, kind="input")), 204)
        start = time.perf_counter_ns()
        self.assertEqual(self.post(dict(page=1, kind="input")), 204)
        with self.assertRaises(TimeoutError):
            self.pages.wait("input", start, page=0, timeout=.02)
        self.assertEqual(self.pages.wait("input", start, page=1)["page"], 1)

    def test_rejects_foreign_origin_and_invalid_page(self):
        self.assertEqual(self.post(dict(page=0, kind="input"), origin="https://example.invalid"), 403)
        # The rejected body's bytes are deliberately not consumed; use a new
        # connection, just as a browser would after a rejected probe origin.
        self.connection.close()
        self.assertEqual(self.post(dict(page=2, kind="input")), 400)
        self.assertEqual(self.pages.events, [])

    def test_animation_acknowledgement_must_match_its_input_sequence(self):
        start = time.perf_counter_ns()
        self.assertEqual(self.post(dict(page=1, kind="input_frame_callbacks", input_sequence=3)), 204)
        with self.assertRaises(TimeoutError):
            self.pages.wait("input_frame_callbacks", start, page=1, input_sequence=4, timeout=.02)
        self.assertEqual(self.post(dict(page=1, kind="input_frame_callbacks", input_sequence=4)), 204)
        self.assertEqual(self.pages.wait("input_frame_callbacks", start, page=1,
                                        input_sequence=4)["input_sequence"], 4)

    def test_only_named_synthetic_pages_are_served(self):
        self.connection.request("GET", f"/{self.pages.token}/1")
        response = self.connection.getresponse()
        page = response.read().decode()
        self.assertEqual(response.status, 200)
        self.assertIn("const page = 1;", page)
        self.assertIn("!e.isTrusted", page)
        self.connection.request("GET", "/unknown")
        response = self.connection.getresponse()
        response.read()
        self.assertEqual(response.status, 404)
