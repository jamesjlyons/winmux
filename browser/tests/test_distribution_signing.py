from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import package_alpha


class DistributionSigningTests(TestCase):
    identity = "A" * 40
    developer = f'  1) {identity} "Apple Development: Example (EXAMPLE123)"\n'
    distribution = f'  2) {identity} "Developer ID Application: Example (EXAMPLE123)"\n'

    def test_requires_selected_valid_application_identity(self):
        package_alpha.require_developer_id(self.identity.lower(), self.distribution)
        for listing in (self.developer, "0 valid identities found", self.distribution.replace("A" * 40, "B" * 40),
                        self.distribution.replace("Developer ID Application", "Developer ID Installer")):
            with self.subTest(listing=listing), self.assertRaises(RuntimeError):
                package_alpha.require_developer_id(self.identity, listing)

    def test_wrong_certificate_is_refused_before_build_or_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "new-package"
            arguments = ["package_alpha.py", "--root", str(Path(directory) / "engine"),
                         "--output", str(output), "--views-trial", "--developer-id"]
            with patch.object(sys, "argv", arguments), patch.dict(package_alpha.os.environ,
                    BROWSER_SIGNING_IDENTITY=self.identity, BROWSER_SIGNING_TEAM="EXAMPLE123"), \
                    patch.object(package_alpha.subprocess, "check_output", return_value=self.developer), \
                    patch.object(package_alpha.build_alpha, "acquire_engine_lock") as lock, \
                    patch.object(package_alpha, "package") as build:
                with self.assertRaisesRegex(RuntimeError, "Developer ID Application"):
                    package_alpha.main()
                lock.assert_not_called()
                build.assert_not_called()
                self.assertFalse(output.exists())

    def test_distribution_keeps_upstream_part_policy_and_requires_timestamp(self):
        config = SimpleNamespace(identity=self.identity)
        product = SimpleNamespace(sign_with_identifier=True, identifier="example.part", path="Part.app",
                                  requirements_string=lambda config: "designated => anchor apple generic",
                                  options=SimpleNamespace(to_comma_delimited_string=lambda: "runtime"),
                                  entitlements="part.plist")
        for mode in (False, True):
            with self.subTest(developer_id=mode), patch.object(package_alpha.chromium, "run") as run:
                package_alpha.PackageSigner(mode).codesign(config, product, "/fixture")
                args = run.call_args.args
                self.assertIn("--timestamp" if mode else "--timestamp=none", args)
                self.assertNotIn("--timestamp=none" if mode else "--timestamp", args)
                self.assertEqual(args[args.index("--entitlements") + 1], "/fixture/part.plist")
                self.assertEqual(args[args.index("--options") + 1], "runtime")
                self.assertIn("=designated => anchor apple generic", args)

    def test_final_distribution_requirement_checks_apple_team_bundle_and_certificate_class(self):
        with patch.object(package_alpha.chromium, "run") as run:
            package_alpha.verify_identity(Path("Trial.app"), "example.trial", "EXAMPLE123", True)
            requirement = run.call_args.args[-2]
            for clause in ('anchor apple generic', 'identifier "example.trial"',
                           'certificate leaf[subject.OU] = "EXAMPLE123"',
                           'certificate 1[field.1.2.840.113635.100.6.2.6]',
                           'certificate leaf[field.1.2.840.113635.100.6.1.13]'):
                self.assertIn(clause, requirement)
