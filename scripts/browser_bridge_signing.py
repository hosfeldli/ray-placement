#!/usr/bin/env python3
"""Local AMO preparation/signing. No credentials in argv, source, or logs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from verify_browser_bridge_package import FILES, verify

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "build/browser-bridge-tools"
WEB_EXT_VERSION = "10.7.0"
ACCOUNT = "lima-browser-bridge"


class SigningError(Exception):
    """A deliberately credential-free diagnostic."""


SERVICES = {"WEB_EXT_API_KEY": "com.lima.browser-bridge.amo-issuer",
            "WEB_EXT_API_SECRET": "com.lima.browser-bridge.amo-secret"}


def child_environment(credentials=None):
    # Ignore caller web-ext overrides, injected Node code, and proxy endpoints.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("WEB_EXT_", "NODE_"))
           and key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    if credentials:
        env.update(credentials)
    return env


def credential_values():
    values = {}
    for variable, service in SERVICES.items():
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-a", ACCOUNT,
             "-s", service, "-w"], capture_output=True, timeout=30)
        if result.returncode:
            raise SigningError("AMO Keychain credentials are unavailable. Run the local setup helper.")
        value = result.stdout.decode("utf-8").rstrip("\r\n")
        if not value or any(char.isspace() for char in value):
            raise SigningError("AMO Keychain credential is empty or malformed.")
        values[variable] = value
    return values


def web_ext():
    package = TOOLS / "node_modules/web-ext/package.json"
    if not package.is_file() or json.loads(package.read_text()).get("version") != WEB_EXT_VERSION:
        raise SigningError("Install pinned tooling: npm install --prefix build/browser-bridge-tools "
                         "--no-audit --no-fund --ignore-scripts --save-exact web-ext@" + WEB_EXT_VERSION)
    return str(TOOLS / "node_modules/.bin/web-ext")


def checked_manifest(source):
    manifest = json.loads((source / "manifest.json").read_text())
    gecko = manifest["browser_specific_settings"]["gecko"]
    if gecko["id"] != "lima-browser-bridge@liamhosfeld.com":
        raise SigningError("Unexpected extension identity.")
    if int(gecko["strict_min_version"].split(".")[0]) < 140:
        raise SigningError("Built-in data consent requires Gecko 140 or later.")
    if gecko.get("data_collection_permissions") != {
            "required": ["browsingActivity", "websiteContent"]}:
        raise SigningError("The reviewed browser data disclosure is missing or changed.")
    if manifest.get("permissions") != ["nativeMessaging", "tabs", "activeTab"] or \
            manifest.get("optional_permissions") != ["https://*/*"] or \
            manifest.get("incognito") != "not_allowed":
        raise SigningError("Browser access policy differs from the reviewed scope.")
    version = manifest["version"]
    if not version or any(c not in "0123456789." for c in version):
        raise SigningError("Unexpected extension version.")
    return manifest


def stage_source(destination):
    source = ROOT / "BrowserBridge"
    checked_manifest(source)
    for name in FILES:
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise SigningError("Source entries must be regular files.")
        shutil.copyfile(path, destination / name)


def source_digest(source):
    digest = hashlib.sha256()
    for name in FILES:
        data = (source / name).read_bytes()
        digest.update(name.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
    return digest.hexdigest()


def prepare(source):
    subprocess.run([web_ext(), "lint", "--source-dir", str(source),
                    "--no-config-discovery", "--no-input", "--self-hosted",
                    "--warnings-as-errors"], check=True, env=child_environment())
    subprocess.run([sys.executable, str(ROOT / "scripts/package_browser_bridge.py")], check=True)
    verify(ROOT / "build/lima-browser-bridge-unsigned.xpi")
    print("Preparation passed. No AMO submission or browser installation occurred.")


def sign_command(source, artifacts):
    return [web_ext(), "sign", "--source-dir", str(source), "--artifacts-dir", str(artifacts),
            "--no-config-discovery", "--no-input", "--channel", "unlisted",
            "--amo-base-url", "https://addons.mozilla.org/api/v5/",
            "--timeout", "120000", "--approval-timeout", "300000"]


def record(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def submit(source):
    manifest = checked_manifest(source)
    digest = source_digest(source)
    work = ROOT / "build/browser-bridge-signing" / manifest["version"]
    # One attempt per version. Never automatically resubmit an uncertain upload.
    work.mkdir(parents=True, exist_ok=True)
    receipt_path = work / "submission.json"
    if receipt_path.exists():
        raise SigningError("This version has a submission record. Check AMO before any retry; "
                         "download the existing signed XPI if approval completed.")
    credentials = credential_values()
    artifacts = work / "artifacts"
    artifacts.mkdir(exist_ok=False)
    receipt = {"version": manifest["version"], "sourceSHA256": digest,
               "channel": "unlisted", "state": "submission-started",
               "browserTrustVerified": False, "liveAcceptance": "pending"}
    record(receipt_path, receipt)
    try:
        # Suppress raw CLI/network output, which can include credential-bearing errors.
        # Secrets are inherited environment values, never command-line arguments.
        with tempfile.TemporaryFile() as output:
            result = subprocess.run(sign_command(source, artifacts), env=child_environment(credentials),
                                    stdout=output, stderr=subprocess.STDOUT, timeout=480)
        candidates = list(artifacts.glob("*.xpi"))
        if result.returncode or len(candidates) != 1:
            raise SigningError("AMO did not return one signed XPI. Check the developer dashboard; "
                             "approval may still be pending. No automatic resubmission.")
        package = candidates[0]
        verify(package, require_signature=True)
        if source_digest(ROOT / "BrowserBridge") != digest:
            raise SigningError("Source changed during signing; do not distribute this artifact.")
        destination = work / "lima-browser-bridge-signed.xpi"
        shutil.copyfile(package, destination)
        receipt.update(state="downloaded-source-verified",
                       xpiSHA256=hashlib.sha256(destination.read_bytes()).hexdigest())
        record(receipt_path, receipt)
        print("Source-matching XPI downloaded: " + str(destination))
        print("Mozilla signature trust and live acceptance still require browser installation.")
    except BaseException:
        receipt["state"] = "needs-dashboard-review"
        record(receipt_path, receipt)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "prepare", "sign"))
    parser.add_argument("--submit", action="store_true", help="Explicitly upload the companion to AMO.")
    args = parser.parse_args()
    if args.action == "status":
        for service in SERVICES.values():
            result = subprocess.run(
                ["/usr/bin/security", "find-generic-password", "-a", ACCOUNT, "-s", service],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            print(service + ": " + ("present" if result.returncode == 0 else "missing/unavailable"))
        return
    if args.action == "sign" and not args.submit:
        raise SigningError("Signing uploads to AMO. Use sign --submit to perform that operation.")
    (ROOT / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bridge-source-", dir=ROOT / "build") as directory:
        source = Path(directory)
        stage_source(source)
        prepare(source)
        if args.action == "sign":
            submit(source)


if __name__ == "__main__":
    try:
        main()
    except (SigningError, ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        # Do not render raw subprocess exceptions or credentials.
        message = str(error) if isinstance(error, SigningError) else "Signing preparation failed; no release was published."
        print(message, file=sys.stderr)
        sys.exit(1)
