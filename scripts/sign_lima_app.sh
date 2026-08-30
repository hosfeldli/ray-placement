#!/bin/zsh
set -euo pipefail

APP_DIRECTORY="${1:?Usage: sign_lima_app.sh <Lima.app>}"
USER_HOME_DIRECTORY="${HOME:?The current user home folder is unavailable}"
SIGNING_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Signing"
LOCAL_SIGNING_KEYCHAIN="$SIGNING_DIRECTORY/RayPlacementSigning.keychain-db"
LOCAL_SIGNING_PASSWORD="$SIGNING_DIRECTORY/keychain-password"
LOCAL_SIGNING_IDENTITY="RayPlacement Local Code Signing"

[[ -d "$APP_DIRECTORY" ]] || { echo "Lima.app is missing: $APP_DIRECTORY" >&2; exit 1; }
[[ -f "$LOCAL_SIGNING_KEYCHAIN" && -f "$LOCAL_SIGNING_PASSWORD" ]] || {
    echo "Lima's stable local signing identity is unavailable. Run scripts/setup_local_signing.sh first." >&2
    exit 1
}

KEYCHAIN_PASSWORD="$(<"$LOCAL_SIGNING_PASSWORD")"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOCAL_SIGNING_KEYCHAIN"
LOCAL_SIGNING_HASH="$(security find-identity -v -p codesigning "$LOCAL_SIGNING_KEYCHAIN" | awk -v identity="$LOCAL_SIGNING_IDENTITY" 'index($0, "\"" identity "\"") { print $2; exit }')"
[[ -n "$LOCAL_SIGNING_HASH" ]] || {
    echo "Lima's local signing identity is not trusted for code signing." >&2
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
echo "Signed Lima with the stable local identity."
