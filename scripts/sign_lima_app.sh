#!/bin/zsh
# Sign an already-built Lima.app with the pinned local signing identity.
#
# This helper signs with Lima's pinned self-signed-local identity. It does not
# modify Git, upload artifacts, or publish a release.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
source "$SCRIPT_DIRECTORY/release_config.sh"

APP_DIRECTORY="${1:?Usage: sign_lima_app.sh <Lima.app>}"
LOCAL_SIGNING_KEYCHAIN="$LIMA_RELEASE_LOCAL_SIGNING_KEYCHAIN"
LOCAL_SIGNING_PASSWORD="$LIMA_RELEASE_LOCAL_SIGNING_PASSWORD"
LOCAL_SIGNING_IDENTITY="$LIMA_RELEASE_SIGNING_IDENTITY"

lima_release_validate_signing_policy
[[ "$LIMA_RELEASE_SIGNING_MODE" == "self-signed-local" ]] || {
    print -u2 "sign_lima_app.sh only supports Lima's self-signed-local policy."
    exit 1
}
[[ -d "$APP_DIRECTORY" ]] || { print -u2 "Lima.app is missing: $APP_DIRECTORY"; exit 1; }
[[ -f "$LOCAL_SIGNING_KEYCHAIN" && -f "$LOCAL_SIGNING_PASSWORD" ]] || {
    print -u2 "Lima's stable local signing identity is unavailable. Run scripts/setup_local_signing.sh first."
    exit 1
}

KEYCHAIN_PASSWORD="$(<"$LOCAL_SIGNING_PASSWORD")"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOCAL_SIGNING_KEYCHAIN"
LOCAL_SIGNING_HASH="$(security find-identity -v -p codesigning "$LOCAL_SIGNING_KEYCHAIN" | awk -v identity="$LOCAL_SIGNING_IDENTITY" 'index($0, "\"" identity "\"") { print $2; exit }')"
[[ -n "$LOCAL_SIGNING_HASH" ]] || {
    print -u2 "Lima's local signing identity is not trusted for code signing."
    exit 1
}

ORIGINAL_USER_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}" )
restore_signing_search_list() {
    security list-keychains -d user -s "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null
}
trap restore_signing_search_list EXIT INT TERM
security list-keychains -d user -s "$LOCAL_SIGNING_KEYCHAIN" "${ORIGINAL_USER_KEYCHAINS[@]}"
codesign --force --deep --sign "$LOCAL_SIGNING_HASH" "$APP_DIRECTORY"
codesign --verify --deep --strict "$APP_DIRECTORY"
restore_signing_search_list
trap - EXIT INT TERM
print "Signed Lima with the stable local identity."
