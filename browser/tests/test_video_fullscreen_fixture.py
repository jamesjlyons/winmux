import json
from pathlib import Path
import sys
from unittest import TestCase
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from test_browser_video_fullscreen import VideoFixture, same_frame


class VideoFullscreenFixtureTests(TestCase):
    def setUp(self):
        self.fixture = VideoFixture({"/": b"video fixture", "/peer": b"peer fixture", "/clip.mp4": b"mp4"})
        self.base = f"http://127.0.0.1:{self.fixture.server.server_port}"

    def tearDown(self):
        self.fixture.close()

    def post(self, value):
        request = Request(self.base + "/event", data=json.dumps(value).encode(),
                          headers={"Content-Type": "application/json"})
        with urlopen(request) as response:
            self.assertEqual(response.status, 204)

    def test_peer_input_cannot_complete_the_video_page_command(self):
        video_sequence = self.fixture.prepare("enter")
        peer_sequence = self.fixture.prepare("ack", True)
        self.post(dict(peer=True, event="input_complete", completed=peer_sequence, trusted=True))
        self.assertEqual(self.fixture.state(), {})
        self.assertEqual(self.fixture.state(True)["completed"], peer_sequence)
        with urlopen(self.base + "/command?peer=false") as response:
            self.assertEqual(json.load(response), dict(sequence=video_sequence, action="enter"))
        with urlopen(self.base + "/command?peer=true") as response:
            self.assertEqual(json.load(response), dict(sequence=peer_sequence, action="ack"))

    def test_transient_fullscreen_failure_survives_later_playback_samples(self):
        self.post(dict(peer=False, event="input_error", error="Fullscreen rejected"))
        self.post(dict(peer=False, event="sample", frames=25))
        self.assertEqual(self.fixture.state()["frames"], 25)
        self.assertEqual(self.fixture.errors[0]["error"], "Fullscreen rejected")
        self.assertEqual(len(self.fixture.events), 1)

    def test_media_served_without_html_fallback(self):
        with urlopen(self.base + "/clip.mp4") as response:
            self.assertEqual(response.headers["Content-Type"], "video/mp4")
            self.assertEqual(response.read(), b"mp4")

    def test_restore_requires_real_geometry_with_bounded_native_rounding(self):
        frame = dict(x=30, y=90, width=600, height=600)
        self.assertFalse(same_frame(None, frame))
        self.assertTrue(same_frame(dict(frame, x=32), frame))
        self.assertFalse(same_frame(dict(frame, width=800), frame))
