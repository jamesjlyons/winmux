import copy
from contextlib import ExitStack, contextmanager
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import build_alpha
import package_alpha


@contextmanager
def alpha_build_fixture(build_args):
    with tempfile.TemporaryDirectory() as directory, ExitStack() as mocks:
        engine = Path(directory)
        source = engine / "chromium/src"
        output = source / "out/WinMuxControl"
        control = source / "out/WinMuxControlBaseline"
        config = engine / "integration"
        for path in (output, control, config / "overlay", config / "patches"):
            path.mkdir(parents=True)
        original_args = b"is_debug = false\n"
        (config / "args.gn").write_bytes(build_args)
        (output / "args.gn").write_bytes(original_args)
        (control / "args.gn").write_bytes(original_args)
        baseline = {"configuration": "browser-only-control", "args_sha256": build_alpha.digest(original_args)}
        (control / "winmux-build-manifest.json").write_text(json.dumps(baseline))
        owner = {"source": str(source), "chromium_revision": build_alpha.chromium.PINS["chromium"]["revision"]}
        (control / "winmux-control-owner.json").write_text(json.dumps(owner))
        (output / "winmux-alpha-owner.json").write_text(json.dumps(owner))
        archived = {p.name: p.read_bytes() for p in control.iterdir()}
        mocks.enter_context(patch.object(build_alpha, "CONFIG", config))
        mocks.enter_context(patch.object(build_alpha.chromium, "preflight", return_value={"blockers": []}))
        mocks.enter_context(patch.object(build_alpha.chromium, "output", side_effect=lambda *args, **kwargs:
            "" if "status" in args else build_alpha.chromium.PINS[
                "depot_tools" if kwargs.get("cwd") == engine / "depot_tools" else "chromium"]["revision"]))
        run = mocks.enter_context(patch.object(build_alpha.chromium, "run"))
        mocks.enter_context(patch.object(build_alpha, "owned_patch_prefix", return_value=0))
        mocks.enter_context(patch("prepare_blocking.prepare", return_value={"library_sha256": "fixture-library"}))
        yield SimpleNamespace(engine=engine, source=source, output=output, control=control,
                              baseline=baseline, archived=archived, run=run,
                              args=SimpleNamespace(jobs=4, allow_configuration_change=False))


class AlphaSafetyTests(TestCase):
    def test_matching_build_records_original_configuration_and_preserves_archive(self):
        with alpha_build_fixture(b"is_debug = false\n") as fixture:
            build_alpha.build(fixture.args, fixture.engine)
            state = json.loads((fixture.engine / "alpha-build-state.json").read_text())
            self.assertTrue(state["build_succeeded"])
            self.assertFalse(state["configuration_changed_from_control"])
            self.assertEqual(state["args_sha256"], state["control_args_sha256"])
            self.assertEqual(state["control_manifest"], fixture.baseline)
            self.assertEqual({p.name: p.read_bytes() for p in fixture.control.iterdir()}, fixture.archived)

    def test_changed_configuration_requires_explicit_flag_and_preserves_original_control(self):
        changed = b"is_debug = false\ndisable_fieldtrial_testing_config = true\n"
        with alpha_build_fixture(changed) as fixture:
            with self.assertRaisesRegex(RuntimeError, "allow-configuration-change"):
                build_alpha.build(fixture.args, fixture.engine)
            fixture.run.assert_not_called()
            self.assertFalse((fixture.engine / "alpha-build-state.json").exists())
            self.assertEqual((fixture.output / "args.gn").read_bytes(), b"is_debug = false\n")
            fixture.args.allow_configuration_change = True
            build_alpha.build(fixture.args, fixture.engine)
            state = json.loads((fixture.output / "winmux-build-manifest.json").read_text())
            self.assertTrue(state["build_succeeded"])
            self.assertTrue(state["configuration_changed_from_control"])
            self.assertEqual(state["args_sha256"], build_alpha.digest(changed))
            self.assertEqual(state["control_args_sha256"], fixture.baseline["args_sha256"])
            self.assertEqual(state["control_manifest"], fixture.baseline)
            self.assertEqual((fixture.output / "args.gn").read_bytes(), changed)
            self.assertEqual({p.name: p.read_bytes() for p in fixture.control.iterdir()}, fixture.archived)
            fixture.args.allow_configuration_change = False
            with self.assertRaisesRegex(RuntimeError, "allow-configuration-change"):
                build_alpha.build(fixture.args, fixture.engine)

    def test_configuration_override_does_not_authorize_unowned_integration_edits(self):
        with alpha_build_fixture(b"is_debug = false\ndisable_fieldtrial_testing_config = true\n") as fixture:
            fixture.args.allow_configuration_change = True
            unowned = fixture.source / "chrome/browser/winmux/WMBridgeProtocol.h"
            unowned.parent.mkdir(parents=True)
            unowned.write_bytes(b"unowned edit")
            with self.assertRaisesRegex(RuntimeError, "Unowned integration edit"):
                build_alpha.build(fixture.args, fixture.engine)
            fixture.run.assert_not_called()
            self.assertEqual(unowned.read_bytes(), b"unowned edit")
            self.assertFalse((fixture.engine / "alpha-build-state.json").exists())
            self.assertEqual({p.name: p.read_bytes() for p in fixture.control.iterdir()}, fixture.archived)

    def test_configuration_override_rejects_failed_or_modified_original_control(self):
        original, changed = b"original", b"changed"
        manifest = {"configuration": "browser-only-control", "args_sha256": build_alpha.digest(original)}
        for bad in ({**manifest, "configuration": "alpha-milestone-0"},
                    {**manifest, "build_succeeded": False}, {**manifest, "args_sha256": "changed"}):
            with self.subTest(manifest=bad), self.assertRaises(RuntimeError):
                build_alpha.configuration_provenance(bad, original, changed, allow_change=True)

    def test_live_build_excludes_duplicate_builds_and_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with build_alpha.acquire_engine_lock(root):
                for exclusive in (True, False):
                    with self.assertRaisesRegex(RuntimeError, "concurrent build"):
                        build_alpha.acquire_engine_lock(root, exclusive=exclusive)
            with build_alpha.acquire_engine_lock(root, exclusive=False):
                with self.assertRaises(RuntimeError):
                    build_alpha.acquire_engine_lock(root)

    def test_resume_accepts_owned_patch_but_preserves_unrelated_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.PIPE)
            git("init")
            source = root / "source.cc"
            source.write_text("before\n")
            second = root / "second.cc"
            second.write_text("second before\n")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture")
            source.write_text("owned change\n")
            patch = git("diff", "--binary", "--full-index", "HEAD")
            first_patch = root / "first.patch"
            first_patch.write_bytes(patch)
            second.write_text("second owned change\n")
            second_patch = root / "second.patch"
            second_patch.write_bytes(git("diff", "--binary", "--full-index", "HEAD", "--", "second.cc"))
            self.assertEqual(build_alpha.owned_patch_prefix(root, [first_patch, second_patch]), 2)
            second.write_text("second before\n")
            self.assertEqual(build_alpha.owned_patch_prefix(root, [first_patch, second_patch]), 1)
            git("config", "core.abbrev", "12")
            self.assertTrue(build_alpha.owned_patch_state(root, patch))
            source.write_text("unrelated work\n")
            with self.assertRaisesRegex(RuntimeError, "Unowned"):
                build_alpha.owned_patch_state(root, patch)
            with self.assertRaisesRegex(RuntimeError, "Unowned"):
                build_alpha.owned_patch_prefix(root, [first_patch, second_patch])
            self.assertEqual(source.read_text(), "unrelated work\n")
            source.write_text("before\n")
            self.assertFalse(build_alpha.owned_patch_state(root, patch))

    def test_packaging_rejects_failed_control_stale_and_escaping_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = "chrome/browser/winmux/workspace_bridge.mm"
            source = root / name
            source.parent.mkdir(parents=True)
            source.write_bytes(b"compiled alpha source")
            manifest = {
                "configuration": "alpha-milestone-0", "build_succeeded": True,
                "chromium_revision": package_alpha.chromium.PINS["chromium"]["revision"],
                "args_sha256": package_alpha.sha256(package_alpha.ROOT / "browser/chromium/args.gn"),
                "patches_sha256": {p.name: package_alpha.sha256(p) for p in build_alpha.integration_patches()},
                "overlay_sha256": {name: hashlib.sha256(source.read_bytes()).hexdigest()},
            }
            package_alpha.validate_manifest(manifest, root)
            for change in ({"build_succeeded": False}, {"configuration": "browser-only-control"},
                           {"patches_sha256": {}}, {"overlay_sha256": {"../outside": "hash"}}):
                invalid = {**copy.deepcopy(manifest), **change}
                with self.subTest(change=change), self.assertRaises(RuntimeError):
                    package_alpha.validate_manifest(invalid, root)
            source.write_bytes(b"new uncompiled edit")
            with self.assertRaisesRegex(RuntimeError, "changed since compilation"):
                package_alpha.validate_manifest(manifest, root)
