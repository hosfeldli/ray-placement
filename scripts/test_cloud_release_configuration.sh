#!/bin/zsh
# Offline regression checks for the cloud-release integration. These assertions
# never authenticate to GCP, inspect secret values, create a keychain, or touch
# release artifacts.
set -euo pipefail

ROOT="${0:A:h:h}"
WORKFLOW="$ROOT/.github/workflows/release-update.yml"
MANIFEST="$ROOT/Packaging/build-assets.json"

for script in \
    prepare_build_assets.sh ci_prepare_signing.sh ci_cleanup_signing.sh \
    archive_release_to_gcs.sh restore_release_from_gcs.sh \
    provision_gcp_release_iam.sh; do
    /bin/zsh -n "$ROOT/scripts/$script"
done

# Temporary OIDC credentials remain ignored. The small signed companion is
# tracked by exact path so tagged hosted builds need no separate GCS upload;
# prepare_build_assets.sh still verifies its pinned digest before packaging.
git -C "$ROOT" check-ignore -q gha-creds-ci.json
git -C "$ROOT" ls-files --error-unmatch -- Packaging/Vendor/BrowserBridge/lima-browser-bridge-1.3.2-signed.xpi >/dev/null

/usr/bin/python3 - "$MANIFEST" "$ROOT" <<'PY'
import hashlib
import json
import os
import re
import sys

manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as source:
    manifest = json.load(source)
assert manifest.get("schemaVersion") == 1
assets = manifest.get("assets")
assert set(assets) == {"whisperModel", "harper", "browserBridgeSignedXPI"}
for name, asset in assets.items():
    assert re.fullmatch(r"[0-9a-f]{64}", asset["sha256"]), name
    assert asset["mode"] in {"0644", "0755"}, name
    destination = asset["destination"]
    assert not os.path.isabs(destination) and ".." not in destination.split("/"), name
    path = os.path.join(root, destination)
    if os.path.isfile(path):
        hasher = hashlib.sha256()
        with open(path, "rb") as candidate:
            for block in iter(lambda: candidate.read(1024 * 1024), b""):
                hasher.update(block)
        assert hasher.hexdigest() == asset["sha256"], f"{name} digest mismatch"
PY

grep -Fq 'id-token: write' "$WORKFLOW"
grep -Fq 'google-github-actions/auth@v3' "$WORKFLOW"
grep -Fq 'google-github-actions/setup-gcloud@v3' "$WORKFLOW"
grep -Fq './scripts/prepare_build_assets.sh' "$WORKFLOW"
grep -Fq 'LIMA_BROWSER_BRIDGE_SIGNED_XPI: ${{ github.workspace }}/Packaging/Vendor/BrowserBridge/lima-browser-bridge-1.3.2-signed.xpi' "$WORKFLOW"
grep -Fq './scripts/ci_prepare_signing.sh' "$WORKFLOW"
grep -Fq './scripts/archive_release_to_gcs.sh' "$WORKFLOW"
grep -Fq './scripts/release_publish.sh --tag "$RELEASE_TAG" --yes' "$WORKFLOW"
grep -Fq './scripts/ci_cleanup_signing.sh' "$WORKFLOW"
if grep -Eq 'LIMA_SIGNING_P12_B64|LIMA_SIGNING_P12_PASSWORD|SPARKLE_EDDSA_PRIVATE_KEY:.*secrets\.' "$WORKFLOW"; then
    print -u2 'Release workflow still references a GitHub release secret.'
    exit 1
fi

LIMA_RELEASE_SIGNING_DIRECTORY=/tmp/lima-cloud-config-test ROOT="$ROOT" /bin/zsh -c '
    source "$ROOT/scripts/release_config.sh"
    [[ "$LIMA_RELEASE_SIGNING_KEYCHAIN" == /tmp/lima-cloud-config-test/RayPlacementSigning.keychain-db ]]
    [[ "$LIMA_RELEASE_LOCAL_SIGNING_KEYCHAIN" == "$LIMA_RELEASE_SIGNING_KEYCHAIN" ]]
'
print 'PASS: cloud release configuration is syntactically valid, secret-free in workflow, and pins local assets.'
