#!/bin/zsh
# Prepare a disposable macOS signing keychain on a GitHub-hosted release runner.
# GCP Secret Manager supplies raw P12 bytes, its password, and the Sparkle key;
# the pinned certificate fingerprint remains source-controlled policy.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
source "$SCRIPT_DIRECTORY/release_config.sh"

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || {
    print -u2 "ci_prepare_signing.sh is restricted to GitHub Actions runners."
    exit 1
}
command -v gcloud >/dev/null 2>&1 || { print -u2 "gcloud is required for CI signing setup."; exit 1; }
command -v security >/dev/null 2>&1 || { print -u2 "macOS security is required for CI signing setup."; exit 1; }

SIGNING_DIRECTORY="${LIMA_RELEASE_SIGNING_DIRECTORY:-${RAYPLACEMENT_SIGNING_DIRECTORY:-${RUNNER_TEMP:?RUNNER_TEMP is required}/lima-signing}}"
KEYCHAIN_PATH="${LIMA_RELEASE_SIGNING_KEYCHAIN:-$SIGNING_DIRECTORY/RayPlacementSigning.keychain-db}"
PASSWORD_FILE="${LIMA_RELEASE_SIGNING_PASSWORD_FILE:-$SIGNING_DIRECTORY/keychain-password}"
CERTIFICATE_FILE="${LIMA_RELEASE_SIGNING_CERTIFICATE:-$SIGNING_DIRECTORY/RayPlacementLocalSigning.cer}"
P12_FILE="$SIGNING_DIRECTORY/RayPlacementSigning.p12"
SPARKLE_KEY_FILE="$SIGNING_DIRECTORY/sparkle-private-key"
P12_SECRET="${LIMA_GCP_SIGNING_P12_SECRET:-lima-signing-p12}"
PASSWORD_SECRET="${LIMA_GCP_SIGNING_P12_PASSWORD_SECRET:-lima-signing-p12-password}"
SPARKLE_SECRET="${LIMA_GCP_SPARKLE_PRIVATE_KEY_SECRET:-lima-sparkle-private-key}"

case "$SIGNING_DIRECTORY" in
    "${RUNNER_TEMP%/}"/*) ;;
    *) print -u2 "CI signing directory must be within RUNNER_TEMP."; exit 1 ;;
esac

umask 077
mkdir -p "$SIGNING_DIRECTORY"
cleanup_on_failure() {
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    rm -rf -- "$SIGNING_DIRECTORY"
}
trap cleanup_on_failure ERR INT TERM

gcloud secrets versions access latest --secret="$P12_SECRET" --out-file="$P12_FILE"
gcloud secrets versions access latest --secret="$PASSWORD_SECRET" --out-file="$PASSWORD_FILE"
gcloud secrets versions access latest --secret="$SPARKLE_SECRET" --out-file="$SPARKLE_KEY_FILE"
chmod 600 "$P12_FILE" "$PASSWORD_FILE" "$SPARKLE_KEY_FILE"

signing_password="$(<"$PASSWORD_FILE")"
[[ -n "$signing_password" ]] || { print -u2 "Signing password secret is empty."; exit 1; }
security create-keychain -p "$signing_password" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$signing_password" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -s "$KEYCHAIN_PATH"
security import "$P12_FILE" -f pkcs12 -k "$KEYCHAIN_PATH" -P "$signing_password" -T /usr/bin/codesign >/dev/null
security find-certificate -a -p -c "$LIMA_RELEASE_SIGNING_IDENTITY" "$KEYCHAIN_PATH" > "$CERTIFICATE_FILE"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERTIFICATE_FILE"
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$signing_password" \
    "$KEYCHAIN_PATH" >/dev/null

actual_certificate="$(/usr/bin/openssl x509 -inform der -in "$CERTIFICATE_FILE" -outform der | /usr/bin/shasum -a 256 | /usr/bin/awk '{print tolower($1)}')"
[[ "$actual_certificate" == "${LIMA_RELEASE_CERTIFICATE_SHA256:l}" ]] || {
    print -u2 "Imported signing certificate does not match Lima's pinned fingerprint."
    exit 1
}
identity_output="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null || true)"
[[ -n "$identity_output" ]] || {
    print -u2 "Imported keychain contains no usable code-signing identity."
    exit 1
}

export RAYPLACEMENT_SIGNING_DIRECTORY="$SIGNING_DIRECTORY"
export RAYPLACEMENT_SIGNING_KEYCHAIN="$KEYCHAIN_PATH"
export RAYPLACEMENT_SIGNING_PASSWORD_FILE="$PASSWORD_FILE"
export RAYPLACEMENT_SIGNING_CERTIFICATE="$CERTIFICATE_FILE"
export SPARKLE_EDDSA_PRIVATE_KEY_FILE="$SPARKLE_KEY_FILE"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        printf 'LIMA_RELEASE_SIGNING_DIRECTORY=%s\n' "$SIGNING_DIRECTORY"
        printf 'LIMA_RELEASE_SIGNING_KEYCHAIN=%s\n' "$KEYCHAIN_PATH"
        printf 'LIMA_RELEASE_SIGNING_PASSWORD_FILE=%s\n' "$PASSWORD_FILE"
        printf 'LIMA_RELEASE_SIGNING_CERTIFICATE=%s\n' "$CERTIFICATE_FILE"
        printf 'RAYPLACEMENT_SIGNING_DIRECTORY=%s\n' "$SIGNING_DIRECTORY"
        printf 'RAYPLACEMENT_SIGNING_KEYCHAIN=%s\n' "$KEYCHAIN_PATH"
        printf 'RAYPLACEMENT_SIGNING_PASSWORD_FILE=%s\n' "$PASSWORD_FILE"
        printf 'RAYPLACEMENT_SIGNING_CERTIFICATE=%s\n' "$CERTIFICATE_FILE"
        printf 'SPARKLE_EDDSA_PRIVATE_KEY_FILE=%s\n' "$SPARKLE_KEY_FILE"
    } >> "$GITHUB_ENV"
fi

trap - ERR INT TERM
print "Prepared ephemeral Lima signing identity with the pinned certificate policy."
