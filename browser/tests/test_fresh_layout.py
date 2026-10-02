import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("reset_workspace_layout", Path(__file__).parents[1] / "tools/reset_workspace_layout.py")
reset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reset)


class FreshLayoutTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        (self.root / "workspace-activation-v1").write_text(reset.ROOT_MARKER)
        self.state = self.root / "daily/native-state"
        self.state.mkdir(parents=True)
        (self.state / "winmux-browser-state-v1").write_text(reset.STATE_MARKER)
        (self.state / "winmux.toml").write_text("original settings")
        (self.state / "window-state.json").write_text("original layout")
        (self.state / "window-state.json.backup").write_text("original backup")
        profile = self.root / "daily/browser-profile/Default"
        profile.mkdir(parents=True)
        self.profile = profile / "retained-test-data"
        self.profile.write_bytes(b"profile data remains identical")
        self.status({"phase": "stopped", "helperPID": 0})
        (self.root / "request.json").write_text(json.dumps({"machService": reset.SERVICE, "browserPath": "/previous/package.app"}))
        self.service = patch.object(reset, "service_is_running", return_value=False)
        self.service.start()
        self.addCleanup(self.service.stop)

    def status(self, value):
        (self.root / "status.json").write_text(json.dumps(value))

    def testArchivesCompleteNativeStateAndRetainsProfile(self):
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        report = reset.archive_layout(self.root)
        archived = Path(report["archive"])
        self.assertFalse(self.state.exists())
        self.assertEqual(before, {p.name: p.read_bytes() for p in archived.iterdir()})
        self.assertEqual(self.profile.read_bytes(), b"profile data remains identical")
        self.assertEqual(report["previousPackage"], "/previous/package.app")
        self.assertTrue(report["browserProfileRetained"])

    def testActiveOrRegisteredWorkspaceCannotReset(self):
        for status in ({"phase": "ready", "helperPID": 123}, {"phase": "starting", "helperPID": 0}, {"phase": "stopped", "helperPID": 123}):
            self.status(status)
            with self.assertRaises(RuntimeError): reset.archive_layout(self.root)
            self.assertTrue(self.state.exists())
        self.status({"phase": "stopped", "helperPID": 0})
        with patch.object(reset, "service_is_running", return_value=True):
            with self.assertRaises(RuntimeError): reset.archive_layout(self.root)
        self.assertFalse((self.root / "layout-archives").exists())

    def testInvalidMarkerAndSymlinkAreRejected(self):
        (self.state / "winmux-browser-state-v1").write_text("unmarked")
        with self.assertRaises(RuntimeError): reset.archive_layout(self.root)
        (self.state / "winmux-browser-state-v1").write_text(reset.STATE_MARKER)
        (self.state / "window-state.json").unlink()
        (self.state / "window-state.json").symlink_to(self.profile)
        with self.assertRaises(RuntimeError): reset.archive_layout(self.root)
        self.assertTrue(self.state.exists())
        self.assertEqual(self.profile.read_bytes(), b"profile data remains identical")

    def testActivationLockAndFixtureRequestAreRejected(self):
        import fcntl
        with (self.root / "activation.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError): reset.archive_layout(self.root)
        (self.root / "request.json").write_text(json.dumps({"machService": "test.fixture", "validationID": "fixture"}))
        with self.assertRaises(RuntimeError): reset.archive_layout(self.root)
        self.assertTrue(self.state.exists())


if __name__ == "__main__": unittest.main()
