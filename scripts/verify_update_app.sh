#!/bin/zsh
set -euo pipefail

# This verifier is shipped inside the installed Lima bundle and is invoked by
# the installed app. The candidate app is data; this script never runs code
# from the candidate bundle.
APP="${1:?Usage: verify_update_app.sh <app> <expected-version> <expected-build> <identity> <certificate-sha256> [policy-app]}"
EXPECTED_VERSION="${2:-}"
EXPECTED_BUILD="${3:-}"
EXPECTED_IDENTITY="${4:-}"
EXPECTED_CERTIFICATE="${5:-}"
POLICY_APP="${6:-$APP}"
PLIST="$APP/Contents/Info.plist"
POLICY_PLIST="$POLICY_APP/Contents/Info.plist"
value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
SIGNING_MODE="$(value "$POLICY_PLIST" LimaUpdateSigningMode 2>/dev/null || print self-signed-local)"
POLICY_VERSION="$(value "$POLICY_PLIST" LimaUpdatePolicyVersion 2>/dev/null || print 0)"
fail() { echo "Update verification failed: $1" >&2; exit 1; }

[[ -d "$APP" && ! -L "$APP" ]] || fail 'app bundle is missing or symbolic'
[[ -f "$PLIST" && -f "$POLICY_PLIST" ]] || fail 'Info.plist is missing'
[[ "$EXPECTED_VERSION" == "" || "$(value "$PLIST" CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]] || fail 'version mismatch'
[[ "$EXPECTED_BUILD" == "" || "$(value "$PLIST" CFBundleVersion)" == "$EXPECTED_BUILD" ]] || fail 'build mismatch'
[[ "$(value "$PLIST" CFBundleIdentifier)" == dev.liam.lima ]] || fail 'bundle identifier is not Lima'
[[ "$(value "$PLIST" CFBundleExecutable)" == Lima ]] || fail 'bundle executable is not Lima'
[[ -x "$APP/Contents/MacOS/Lima" ]] || fail 'Lima executable is missing'
[[ "$SIGNING_MODE" == "self-signed-local" ]] || fail 'only the self-signed-local policy is supported'
[[ "$POLICY_VERSION" == 1 ]] || fail 'the update trust policy version is unsupported'
[[ -n "$EXPECTED_IDENTITY" ]] || fail 'expected signing identity is not configured'
[[ "$EXPECTED_CERTIFICATE" =~ ^[[:xdigit:]]{64}$ ]] || fail 'expected certificate fingerprint is not configured'
[[ "$EXPECTED_IDENTITY" == 'RayPlacement Local Code Signing' ]] || fail 'self-signed local identity is not pinned'

/usr/bin/codesign --verify --deep --strict "$APP" || fail 'code signature is invalid'
SIGNATURE_INFO="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE_INFO" != *'Signature=adhoc'* ]] || fail 'ad-hoc signatures are not accepted'
IDENTITY="$(printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -n 1)"
[[ "$IDENTITY" == "$EXPECTED_IDENTITY" ]] || fail "signing identity mismatch (got '$IDENTITY')"

CERTIFICATE_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR%/}/lima-update-cert.XXXXXX")"
trap '/bin/rm -rf "$CERTIFICATE_DIRECTORY"' EXIT
/usr/bin/codesign -d --extract-certificates="$CERTIFICATE_DIRECTORY/cert" "$APP" >/dev/null 2>&1 || fail 'the app certificate could not be extracted'
LEAF="$CERTIFICATE_DIRECTORY/cert0"
[[ -f "$LEAF" ]] || fail 'the app leaf certificate is missing'
CERTIFICATE_HASH="$(/usr/bin/openssl x509 -inform der -in "$LEAF" -outform der | /usr/bin/shasum -a 256 | /usr/bin/awk '{print toupper($1)}')"
[[ "${CERTIFICATE_HASH:u}" == "${EXPECTED_CERTIFICATE:u}" ]] || fail 'the signing certificate fingerprint is not pinned'

# Never accept links or special files anywhere inside the candidate bundle.
while IFS= read -r item; do
    [[ -L "$item" ]] && fail "symbolic link found: $item"
    [[ -f "$item" || -d "$item" ]] || fail "special file found: $item"
done < <(/usr/bin/find "$APP" -mindepth 1 -print)
echo "Verified signed Lima update: $APP"
