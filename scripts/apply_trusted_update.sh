#!/bin/zsh
# This helper is copied into the installed, trusted Lima bundle. It must not
# execute scripts from the downloaded update archive.
set -euo pipefail
(( $# == 7 )) || { echo 'Usage: apply_trusted_update.sh <pid> <current-app> <source-root> <version> <result-file> <progress-file> <trusted-app>' >&2; exit 2; }
CURRENT_PID="$1"
# Canonicalize once at the boundary. This supports /Applications,
# ~/Applications, spaces, and LaunchServices symlink/alias spellings while
# ensuring every later operation targets the same bundle.
CURRENT_APP="${2:A}"
SOURCE_ROOT="${3:A}"
VERSION="$4"
RESULT_FILE="${5:A}"
PROGRESS_FILE="${6:A}"
TRUSTED_APP="${7:A}"
READY_APP="${SOURCE_ROOT}/Prebuilt/Lima.app"
BUILD=""
UPDATES_DIRECTORY="${HOME:?}/Library/Application Support/Lima/Updates"
TRANSACTION=""
write() { local d="$1"; shift; local t="$d.tmp.$$"; mkdir -p "${d:h}"; printf '%s\n' "$@" > "$t"; chmod 600 "$t"; mv "$t" "$d"; }
fail() { local message="$1"; write "$RESULT_FILE" failure "$message"; write "$PROGRESS_FILE" failure 0 "$message"; exit 1; }
trap '[[ $? -eq 0 ]] || fail "The trusted updater stopped unexpectedly. The current app was preserved."' EXIT
[[ "$CURRENT_PID" == <-> && "$CURRENT_PID" -gt 1 ]] || fail 'The running app process is invalid.'
[[ -d "$READY_APP" ]] || fail 'The verified app is missing.'
[[ "$CURRENT_APP" == /* && "$CURRENT_APP" == *.app && -d "$CURRENT_APP" && ! -L "$CURRENT_APP" ]] || fail "The running Lima bundle is not a canonical app path: $CURRENT_APP"
[[ -f "$CURRENT_APP/Contents/Info.plist" && -x "$CURRENT_APP/Contents/MacOS/Lima" ]] || fail "The running Lima bundle is incomplete: $CURRENT_APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CURRENT_APP/Contents/Info.plist")" == dev.liam.lima ]] || fail "The running bundle is not Lima: $CURRENT_APP"
[[ "$TRUSTED_APP" == /* && "$TRUSTED_APP" == *.app && -d "$TRUSTED_APP" && ! -L "$TRUSTED_APP" ]] || fail 'The trusted app path is invalid.'
TRUSTED_RESOURCES="$TRUSTED_APP/Contents/Resources/Updater"
[[ -x "$TRUSTED_RESOURCES/verify_update_app.sh" && -x "$TRUSTED_RESOURCES/approved_lima_replacement.sh" ]] || fail 'Trusted updater resources are missing.'
TRUSTED_INFO="$TRUSTED_APP/Contents/Info.plist"
POLICY_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LimaUpdatePolicyVersion' "$TRUSTED_INFO")" || fail 'The installed app has no update trust policy version.'
[[ "$POLICY_VERSION" == 1 ]] || fail "The installed app uses unsupported update trust policy version: $POLICY_VERSION"
EXPECTED_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :LimaUpdateExpectedTeamIdentifier' "$TRUSTED_INFO")" || fail 'The installed app has no expected Team ID policy.'
EXPECTED_IDENTITY="$(/usr/libexec/PlistBuddy -c 'Print :LimaUpdateExpectedSigningIdentity' "$TRUSTED_INFO")" || fail 'The installed app has no expected signing identity policy.'
EXPECTED_CERTIFICATE="$(/usr/libexec/PlistBuddy -c 'Print :LimaUpdateExpectedCertificateSHA256' "$TRUSTED_INFO")" || fail 'The installed app has no certificate policy.'
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$READY_APP/Contents/Info.plist")"
write "$PROGRESS_FILE" working 0.42 "Verifying the complete signed Lima app…"
"$TRUSTED_RESOURCES/verify_update_app.sh" "$READY_APP" "$VERSION" "$BUILD" "$EXPECTED_TEAM_ID" "$EXPECTED_IDENTITY" "$EXPECTED_CERTIFICATE" "$TRUSTED_APP" || fail 'The incoming app failed trusted verification.'
write "$PROGRESS_FILE" working 0.60 "Preparing the verified replacement…"
TRANSACTION="${CURRENT_APP:h}/.lima-install.$(/usr/bin/uuidgen)" || fail 'Could not create an installation transaction.'
[[ ! -e "$TRANSACTION" && ! -L "$TRANSACTION" ]] || fail 'The installation transaction path is already in use.'
if [[ -w "${CURRENT_APP:h}" ]]; then
    write "$PROGRESS_FILE" ready 0.90 "Lima is verified. It will close briefly, install, and reopen…"
    for _ in {1..240}; do kill -0 "$CURRENT_PID" 2>/dev/null || break; sleep 0.25; done
    kill -0 "$CURRENT_PID" 2>/dev/null && fail 'Lima did not close in time.'
    write "$PROGRESS_FILE" installing 0.96 "Replacing the installed Lima app…"
    if ! "$TRUSTED_RESOURCES/approved_lima_replacement.sh" "$READY_APP" "$CURRENT_APP" "$VERSION" "$BUILD" "$CURRENT_PID" "$TRANSACTION"; then
        /usr/bin/open -n "$CURRENT_APP" || true
        fail 'The app replacement failed. The previous app was preserved.'
    fi
else
    AUTH_LOG="$UPDATES_DIRECTORY/administrator-update.log"
    "$TRUSTED_RESOURCES/request_lima_update_approval.sh" "$CURRENT_PID" "$READY_APP" "$CURRENT_APP" "$VERSION" "$BUILD" "$TRANSACTION" "$PROGRESS_FILE" "$AUTH_LOG" "$TRUSTED_APP" || fail 'Administrator-approved replacement failed. The current app was preserved.'
fi
/usr/bin/codesign --verify --deep --strict "$CURRENT_APP" || fail 'The installed app failed final signature verification.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CURRENT_APP/Contents/Info.plist")" == "$VERSION" ]] || fail 'The installed version does not match.'
write "$RESULT_FILE" success "Lima $VERSION ($BUILD) installed at $CURRENT_APP." "$VERSION" "$BUILD" "$CURRENT_APP"
write "$PROGRESS_FILE" success 1 "Lima $VERSION is installed. Reopening the updated copy…"
/usr/bin/open -n "$CURRENT_APP" || fail 'Lima was installed but could not reopen.'
trap - EXIT
