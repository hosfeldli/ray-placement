#!/usr/bin/env python3
"""Offline signing regressions; never contact AMO or access the real Keychain."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import browser_bridge_signing as signing


class SigningTests(unittest.TestCase):
    def setUp(self):
        # Suppress fixture-only success messages so logs cannot resemble real signing.
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "build").mkdir()
        shutil.copytree(ROOT / "BrowserBridge", self.root / "BrowserBridge")
        self.staged = self.root / "staged"
        self.staged.mkdir()
        self.override = patch.object(signing, "ROOT", self.root)
        self.override.start()
        signing.stage_source(self.staged)

    def tearDown(self):
        self.override.stop()
        self.temp.cleanup()
        self.output.__exit__(None, None, None)

    def change_manifest(self, change):
        path = self.root / "BrowserBridge/manifest.json"
        data = json.loads(path.read_text())
        change(data)
        path.write_text(json.dumps(data))

    def test_current_manifest_has_truthful_consent_and_site_scope(self):
        self.assertEqual(signing.checked_manifest(self.staged)["incognito"], "not_allowed")

    def test_missing_consent_and_older_gecko_fail_closed(self):
        for key, value in (("data_collection_permissions", {"required": ["none"]}),
                           ("strict_min_version", "115.0")):
            self.change_manifest(lambda m: m["browser_specific_settings"]["gecko"].update({key: value}))
            with self.assertRaises(signing.SigningError):
                signing.checked_manifest(self.root / "BrowserBridge")

    def test_expanded_site_scope_is_rejected(self):
        self.change_manifest(lambda m: m.update(permissions=["<all_urls>"]))
        with self.assertRaises(signing.SigningError):
            signing.checked_manifest(self.root / "BrowserBridge")

    def test_staging_contains_only_reviewed_files(self):
        (self.root / "BrowserBridge/credentials.txt").write_text("NEVER_UPLOAD")
        signing.stage_source(self.staged)
        self.assertEqual(set(p.name for p in self.staged.iterdir()), set(signing.FILES))

    def test_environment_discards_endpoint_and_code_injection_overrides(self):
        with patch.dict(os.environ, {"WEB_EXT_API_SECRET": "ambient-secret",
                                     "WEB_EXT_AMO_BASE_URL": "https://invalid.test",
                                     "NODE_OPTIONS": "--require injected.js",
                                     "HTTPS_PROXY": "https://invalid.test"}, clear=True):
            self.assertEqual(signing.child_environment(), {})
            self.assertEqual(signing.child_environment({"WEB_EXT_API_SECRET": "keychain-secret"}),
                             {"WEB_EXT_API_SECRET": "keychain-secret"})

    def test_secrets_are_not_command_arguments(self):
        with patch.object(signing, "web_ext", return_value="/fixed/web-ext"):
            command = signing.sign_command(self.staged, self.root)
        self.assertNotIn("--api-key", command)
        self.assertNotIn("--api-secret", command)
        self.assertIn("--no-config-discovery", command)
        self.assertIn("unlisted", command)
        self.assertIn("https://addons.mozilla.org/api/v5/", command)

    def test_sign_requires_explicit_upload_before_any_other_operation(self):
        with patch.object(sys, "argv", ["signing", "sign"]), \
             patch.object(signing, "credential_values") as credentials:
            with self.assertRaises(signing.SigningError):
                signing.main()
            credentials.assert_not_called()

    def test_unavailable_credentials_do_not_create_submission_receipt(self):
        with patch.object(signing, "credential_values", side_effect=signing.SigningError("missing")):
            with self.assertRaises(signing.SigningError):
                signing.submit(self.staged)
        self.assertFalse(list((self.root / "build").rglob("submission.json")))

    def fake_submit(self, command, **kwargs):
        self.assertEqual(kwargs["env"]["WEB_EXT_API_SECRET"], "fixture-secret")
        self.assertNotIn("fixture-secret", " ".join(command))
        artifacts = Path(command[command.index("--artifacts-dir") + 1])
        with zipfile.ZipFile(artifacts / "fixture.xpi", "w") as archive:
            for name in signing.FILES:
                archive.writestr(name, (self.staged / name).read_bytes())
            # Deliberately fake metadata; only a browser can verify real trust.
            archive.writestr("META-INF/cose.sig", b"NOT_A_REAL_SIGNATURE")
            archive.writestr("META-INF/cose.manifest", b"fixture")
        return subprocess.CompletedProcess(command, 0)

    def submission_mocks(self):
        return patch.object(signing, "credential_values", return_value={
            "WEB_EXT_API_KEY": "fixture-issuer", "WEB_EXT_API_SECRET": "fixture-secret"})

    def test_download_records_source_but_never_claims_mozilla_trust(self):
        with self.submission_mocks(), patch.object(signing, "web_ext", return_value="/fixed/web-ext"), \
             patch.object(signing.subprocess, "run", side_effect=self.fake_submit):
            signing.submit(self.staged)
        receipt = json.loads(next((self.root / "build").rglob("submission.json")).read_text())
        self.assertEqual(receipt["state"], "downloaded-source-verified")
        self.assertFalse(receipt["browserTrustVerified"])
        self.assertEqual(receipt["liveAcceptance"], "pending")
        self.assertEqual(len(receipt["xpiSHA256"]), 64)
        self.assertNotIn("fixture-secret", json.dumps(receipt))

    def test_uncertain_submission_cannot_be_blindly_retried(self):
        with self.submission_mocks(), patch.object(signing, "web_ext", return_value="/fixed/web-ext"), \
             patch.object(signing.subprocess, "run", side_effect=subprocess.TimeoutExpired("web-ext", 480)):
            with self.assertRaises(subprocess.TimeoutExpired):
                signing.submit(self.staged)
        receipt = json.loads(next((self.root / "build").rglob("submission.json")).read_text())
        self.assertEqual(receipt["state"], "needs-dashboard-review")
        with patch.object(signing, "credential_values") as credentials:
            with self.assertRaises(signing.SigningError):
                signing.submit(self.staged)
            credentials.assert_not_called()

    def test_source_change_during_signing_rejects_distribution_copy(self):
        def changed(command, **kwargs):
            result = self.fake_submit(command, **kwargs)
            with (self.root / "BrowserBridge/popup.html").open("a") as output:
                output.write("changed")
            return result
        with self.submission_mocks(), patch.object(signing, "web_ext", return_value="/fixed/web-ext"), \
             patch.object(signing.subprocess, "run", side_effect=changed):
            with self.assertRaises(signing.SigningError):
                signing.submit(self.staged)
        self.assertFalse(list((self.root / "build").rglob("lima-browser-bridge-signed.xpi")))


if __name__ == "__main__":
    unittest.main()
