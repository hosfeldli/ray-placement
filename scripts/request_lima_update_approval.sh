#!/bin/zsh -f
# Runs only as the logged-in user. Approval is delegated to macOS, never sudo,
# a saved password, a persistent helper, or a change to folder permissions.
set -euo pipefail
(( $# == 8 && EUID != 0 )) || { print -ru2 -- 'Approval must start as the signed-in user with a complete request.'; exit 2; }
CURRENT_PID="$1"
READY_APP="$2"
INSTALLED_APP="$3"
VERSION="$4"
BUILD="$5"
TRANSACTION="$6"
PROGRESS_FILE="$7"
AUTH_LOG="$8"
APPROVAL_RESOURCES="$READY_APP/Contents/Resources/Updater"
fail() { print -ru2 -- "$1"; exit 1; }
write_progress() {
    local temporary="$PROGRESS_FILE.tmp.$$"
    printf '%s\n' "$@" > "$temporary"
    /bin/mv "$temporary" "$PROGRESS_FILE"
}
: > "$AUTH_LOG"
[[ -f "$APPROVAL_RESOURCES/approved_lima_replacement.sh" && -f "$APPROVAL_RESOURCES/authorize_lima_update.applescript" ]] || fail 'This update is missing its signed approval resources.'
/usr/bin/codesign --verify --deep --strict "$INSTALLED_APP" || fail 'The installed signature is invalid.'
INSTALLED_REQUIREMENT="$(/usr/bin/codesign -d -r- "$INSTALLED_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
[[ -n "$INSTALLED_REQUIREMENT" && "$INSTALLED_REQUIREMENT" != *cdhash* && ( "$INSTALLED_REQUIREMENT" == *anchor* || "$INSTALLED_REQUIREMENT" == *certificate* ) ]] || fail 'This installation has no stable signing identity. Install the official DMG once using Finder.'
/usr/bin/codesign --verify --deep --strict -R "=$INSTALLED_REQUIREMENT" "$READY_APP" || fail 'The incoming update does not match the installed signing identity.'
APPROVED_PROGRAM="$(<"$APPROVAL_RESOURCES/approved_lima_replacement.sh")"
/usr/bin/codesign --verify --deep --strict -R "=$INSTALLED_REQUIREMENT" "$READY_APP" || fail 'The signed approval resources changed. Download the update again.'
write_progress working 0.72 'Approve the macOS administrator prompt (osascript) to update Lima. Cancel keeps your current app running.'
/usr/bin/osascript "$APPROVAL_RESOURCES/authorize_lima_update.applescript" "$APPROVED_PROGRAM" "$READY_APP" "$INSTALLED_APP" "$VERSION" "$BUILD" "$CURRENT_PID" "$TRANSACTION" > "$AUTH_LOG" 2>&1 &
AUTH_PID=$!
READY_REPORTED=0
while kill -0 "$AUTH_PID" 2>/dev/null; do
    if (( ! READY_REPORTED )) && [[ -f "$TRANSACTION/Ready" && ! -L "$TRANSACTION/Ready" && "$(/usr/bin/stat -f %u "$TRANSACTION/Ready")" == 0 ]]; then
        READY_REPORTED=1
        write_progress ready 0.90 'Administrator approval received. Lima is staged and verified; closing briefly to install…'
    fi
    /bin/sleep 0.25
done
if ! wait "$AUTH_PID"; then
    /bin/cat "$AUTH_LOG"
    if /usr/bin/grep -q -- '-128' "$AUTH_LOG"; then
        print -ru2 -- 'Administrator approval was canceled. The current app is unchanged.'
        exit 125
    fi
    fail 'Administrator-approved replacement did not complete. See administrator-update.log.'
fi
/bin/cat "$AUTH_LOG"
