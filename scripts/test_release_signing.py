"""Release identity and fail-closed checks; never access private keys or user grants."""
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sign_release_app as signing

TEAM = "ABCD123456"
HASH = "A" * 40
NAME = f"Developer ID Application: Example ({TEAM})"


class ReleaseSigningTests(unittest.TestCase):
    def test_exact_certificate_fingerprint_and_team(self):
        listing = f'  1) {HASH} "{NAME}"\n  1 valid identities found\n'
        self.assertEqual(signing.select_identity(listing, HASH.lower(), TEAM), HASH)
        self.assertEqual(signing.select_identity(listing, NAME, TEAM), HASH)
        with self.assertRaises(ValueError):
            signing.select_identity(listing, HASH, "OTHER12345")

    def test_missing_ambiguous_or_non_distribution_identity_is_rejected(self):
        cases = [
            ("0 valid identities found", HASH),
            (f'1) {HASH} "{NAME}"', "-"),
            (f'1) {HASH} "{NAME}"', ""),
            (f'1) {HASH} "Developer ID Installer: Example ({TEAM})"', HASH),
            (f'1) {HASH} "Apple Development: Example ({TEAM})"', HASH),
            (f'1) {HASH} "{NAME}" (CSSMERR_TP_CERT_EXPIRED)', HASH),
            (f'1) {HASH} "{NAME}"\n2) {"B" * 40} "{NAME}"', NAME),
        ]
        for listing, requested in cases:
            with self.subTest(requested=requested, listing=listing), self.assertRaises(ValueError):
                signing.select_identity(listing, requested, TEAM)

    def test_signing_failure_does_not_continue_to_outer_app(self):
        app = Path("/test/Spoken.app")
        helper = app / "helper"
        failure = subprocess.CalledProcessError(1, "codesign", stderr="Signing denied")
        with patch.object(signing, "signing_identity", return_value=HASH), \
             patch.object(signing, "signing_targets", return_value=[helper, app]), \
             patch.object(signing, "run", side_effect=failure) as runner:
            with self.assertRaises(subprocess.CalledProcessError):
                signing.sign(app)
            self.assertEqual(runner.call_count, 1)
            self.assertEqual(runner.call_args.args[-1], helper)

    def test_designated_requirement_on_stdout_cannot_pin_one_build(self):
        app = Path("/test/Spoken.app")
        details = f'TeamIdentifier={TEAM}\nTimestamp=Oct 3, 2026\nflags=0x10000(runtime)\n'
        output = [subprocess.CompletedProcess([], 0, "", details),
                  subprocess.CompletedProcess([], 0, 'designated => cdhash H"123"', "")]
        with patch.object(signing, "signing_targets", return_value=[app]), \
             patch.object(signing, "run", side_effect=output):
            with self.assertRaisesRegex(ValueError, "Build-specific"):
                signing.verify_release_app(app, TEAM)

    def test_real_adhoc_bundle_is_rejected(self):
        # A disposable bundle exercises the actual codesign metadata format.
        with tempfile.TemporaryDirectory(prefix="spoken-signing-test-") as directory:
            app = Path(directory) / "Spoken.app"
            macos = app / "Contents/MacOS"
            macos.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.moss.spoken", "CFBundleExecutable": "Spoken",
                "CFBundlePackageType": "APPL"}))
            subprocess.run(["cp", "/usr/bin/true", str(macos / "Spoken")], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with patch.object(signing, "signing_targets", return_value=[app]):
                with self.assertRaisesRegex(ValueError, "Missing Developer ID"):
                    signing.verify_release_app(app, TEAM)
            # Even if display metadata were misleading, actual certificate-chain
            # verification must reject this app, using a valid inline requirement.
            real_run = signing.run
            def misleading_display(*args):
                if "--display" in args:
                    details = f'TeamIdentifier={TEAM}\nTimestamp=Oct 3, 2026\nflags=0x10000(runtime)\n'
                    return subprocess.CompletedProcess(args, 0, "", details)
                return real_run(*args)
            with patch.object(signing, "signing_targets", return_value=[app]), \
                 patch.object(signing, "run", side_effect=misleading_display):
                with self.assertRaises(subprocess.CalledProcessError) as error:
                    signing.verify_release_app(app, TEAM)
                self.assertIn("failed to satisfy", error.exception.stderr)
                self.assertNotIn("invalid requirement specification", error.exception.stderr)

    def test_release_build_stops_before_creating_artifacts_without_configuration(self):
        with tempfile.TemporaryDirectory(prefix="spoken-build-preflight-") as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ["build_release_app.sh", "build_local_app.sh", "sign_release_app.py"]:
                (scripts / name).write_bytes((signing.ROOT / "scripts" / name).read_bytes())
            env = {k: v for k, v in os.environ.items() if not k.startswith("SPOKEN_")}
            result = subprocess.run(["bash", str(scripts / "build_release_app.sh")],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SPOKEN_TEAM_ID", result.stderr)
            self.assertFalse((root / "build").exists())


if __name__ == "__main__":
    unittest.main()
