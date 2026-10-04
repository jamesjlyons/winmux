import fcntl
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import workspace_views_trial as trial


class WorkspaceViewsTrialTests(unittest.TestCase):
    def test_existing_native_lease_blocks_start_without_changing_owner(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "lease"
            path.write_text("daily manager")
            with path.open("r+") as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(RuntimeError, "current workspace is running"):
                    trial.check_unowned(path)
                self.assertEqual(path.read_text(), "daily manager")
            trial.check_unowned(path)

    def test_refused_start_does_not_launch_or_stop_anything(self):
        with patch.object(trial, "check_unowned", side_effect=RuntimeError("occupied")), \
             patch.object(trial.subprocess, "Popen") as launch, patch.object(trial, "stop") as stop:
            with self.assertRaisesRegex(RuntimeError, "occupied"):
                trial.start(Path("/unused"), {})
            launch.assert_not_called()
            stop.assert_not_called()

    def test_stop_ignores_reused_pid_and_only_removes_trial_service(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "run.json").write_text(json.dumps({"fixture": {"pid": 42}}))
            service = "com.jameslyons.winmux.browser.alpha.workspace.test.fixture"
            with patch.object(trial, "is_same_process", return_value=False), \
                 patch.object(trial.subprocess, "run") as command, patch.object(trial.os, "kill") as kill:
                trial.stop(directory, {"service": service})
                kill.assert_not_called()
                self.assertEqual(command.call_args.args[0], ["launchctl", "bootout", f"gui/{trial.os.getuid()}/{service}"])
                self.assertFalse((directory / "run.json").exists())

    def test_process_identity_requires_start_time_and_executable_uuid(self):
        record = {"pid": 42, "executable": "/fixture", "start": 100, "uuid": "abc"}
        with patch.object(trial, "identity", return_value={**record, "start": 101}):
            self.assertFalse(trial.is_same_process(record))
        with patch.object(trial, "identity", return_value={**record, "uuid": "different"}):
            self.assertFalse(trial.is_same_process(record))
        with patch.object(trial, "identity", return_value=record):
            self.assertTrue(trial.is_same_process(record))

    def test_prepare_rejects_changed_package_before_creating_trial(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            app = directory / "Candidate.app"
            app.mkdir()
            (app / "helper").write_bytes(b"changed")
            (directory / "winmux-package-manifest.json").write_text(json.dumps({
                "verified": True, "helper_relative_path": "helper", "helper_sha256": hashlib.sha256(b"original").hexdigest(),
            }))
            output = directory / "trial"
            with self.assertRaisesRegex(RuntimeError, "helper changed"):
                trial.prepare(output, app)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
