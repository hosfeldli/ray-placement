#!/bin/zsh -f
# This fixed program is passed BY VALUE to macOS authorization. No script file,
# app binary, hook, or user tool is executed after elevation; only system tools.
set -euo pipefail
setopt EXTENDED_GLOB
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset CDPATH ENV BASH_ENV ZDOTDIR
umask 077
(( $# == 6 )) || exit 2
SOURCE_APP="$1"
DESTINATION_APP="$2"
EXPECTED_VERSION="$3"
EXPECTED_BUILD="$4"
CURRENT_PID="$5"
TRANSACTION="$6"
PARENT="${DESTINATION_APP:h}"
STAGED="$TRANSACTION/Incoming.app"
PREVIOUS="$TRANSACTION/Previous.app"
SWAPPED=0

fail() { print -ru2 -- "$1"; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
for path_value in "$SOURCE_APP" "$DESTINATION_APP" "$TRANSACTION"; do
    [[ "$path_value" == /* && "$path_value" != *$'\n'* && "$path_value" != *$'\r'* ]] || fail 'Invalid update path.'
    [[ "$path_value" == "${path_value:A}" ]] || fail 'Symlinked update paths are not allowed.'
done
[[ "$DESTINATION_APP" == /*.app && -d "$DESTINATION_APP" && ! -L "$DESTINATION_APP" ]] || fail 'The installed app is missing or is a symbolic link.'
[[ "$DESTINATION_APP" != /Volumes/* && "$DESTINATION_APP" != /System/* && "$DESTINATION_APP" != *'/AppTranslocation/'* ]] || fail 'This location cannot be updated.'
[[ -d "$SOURCE_APP" && "$SOURCE_APP" == /*.app && "$SOURCE_APP" != "$DESTINATION_APP" ]] || fail 'The incoming app location is invalid.'
[[ "${TRANSACTION:h}" == "$PARENT" && "${TRANSACTION:t}" == .lima-install.[A-Fa-f0-9-]## && ! -e "$TRANSACTION" && ! -L "$TRANSACTION" ]] || fail 'Invalid or occupied installation transaction.'
[[ "$CURRENT_PID" == <-> && "$CURRENT_PID" -gt 1 ]] || fail 'Invalid running app process.'
[[ "$(value "$DESTINATION_APP" CFBundleIdentifier)" == dev.liam.lima ]] || fail 'Refusing to replace an unrelated app.'
/usr/bin/codesign --verify --deep --strict "$DESTINATION_APP" || fail 'The installed app signature is invalid.'
SIGNATURE_INFO="$(/usr/bin/codesign -dvv "$DESTINATION_APP" 2>&1)"
[[ "$SIGNATURE_INFO" != *'Signature=adhoc'* && "$SIGNATURE_INFO" == *'Authority='* ]] || fail 'Protected updates need a signed Lima installation. Install the official DMG once using Finder.'
REQUIREMENT="$(/usr/bin/codesign -d -r- "$DESTINATION_APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
[[ -n "$REQUIREMENT" && "$REQUIREMENT" != *cdhash* && ( "$REQUIREMENT" == *anchor* || "$REQUIREMENT" == *certificate* ) ]] || fail 'The installed signing identity cannot authorize a protected update.'
OLD_VERSION="$(value "$DESTINATION_APP" CFBundleShortVersionString)"
OLD_BUILD="$(value "$DESTINATION_APP" CFBundleVersion)"
OLD_CDHASH="$(/usr/bin/codesign -dvvvv "$DESTINATION_APP" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
[[ -n "$OLD_CDHASH" ]] || fail 'The installed signature could not be identified.'

rollback() {
    local result=$?
    if (( result != 0 && SWAPPED )); then
        if [[ -e "$DESTINATION_APP" ]]; then
            /bin/mv "$DESTINATION_APP" "$TRANSACTION/Failed.app" || {
                print -ru2 -- "Recovery required: the previous app is at $PREVIOUS"
                exit "$result"
            }
        fi
        if /bin/mv "$PREVIOUS" "$DESTINATION_APP"; then
            print -ru2 -- 'Replacement failed; the previous Lima app was restored.'
        else
            print -ru2 -- "Recovery required: the previous app is at $PREVIOUS"
        fi
    fi
    exit "$result"
}
trap rollback EXIT
# Atomic directory creation refuses preexisting paths; the staged app is never
# writable by the requesting account once an administrator has approved it.
/bin/mkdir -m 700 "$TRANSACTION"
/bin/chmod -N "$TRANSACTION"
/usr/bin/ditto "$SOURCE_APP" "$STAGED"
# File modes/ACLs are not covered by a code signature. Strip privilege bits and
# inherited write grants BEFORE making a root-owned staged app accessible.
/bin/chmod -RPN "$STAGED"
/bin/chmod -RP u-s,g-s,go-w "$STAGED"
if (( EUID == 0 )); then /usr/sbin/chown -Rh 0:0 "$STAGED"; fi
/usr/bin/codesign --verify --deep --strict -R "=$REQUIREMENT" "$STAGED" || fail 'The update does not match the installed signing identity.'
[[ "$(value "$STAGED" CFBundleIdentifier)" == dev.liam.lima && "$(value "$STAGED" CFBundleExecutable)" == Lima ]] || fail 'The incoming bundle is not Lima.'
[[ "$(value "$STAGED" CFBundleShortVersionString)" == "$EXPECTED_VERSION" && "$(value "$STAGED" CFBundleVersion)" == "$EXPECTED_BUILD" ]] || fail 'The incoming version does not match the approved update.'
[[ -f "$STAGED/Contents/MacOS/Lima" && ! -L "$STAGED/Contents/MacOS/Lima" ]] || fail 'Invalid Lima executable.'
# The unprivileged parent observes this root-owned marker and updates the UI.
# No privileged process writes to user-chosen progress/log/receipt paths.
/usr/bin/touch "$TRANSACTION/Ready"
/bin/chmod 444 "$TRANSACTION/Ready"
/bin/chmod 711 "$TRANSACTION"
for _ in {1..360}; do
    /bin/kill -0 "$CURRENT_PID" 2>/dev/null || break
    /bin/sleep 0.25
done
/bin/kill -0 "$CURRENT_PID" 2>/dev/null && fail 'Lima did not close in time; the current app is unchanged.'
[[ "$(value "$DESTINATION_APP" CFBundleShortVersionString)" == "$OLD_VERSION" && "$(value "$DESTINATION_APP" CFBundleVersion)" == "$OLD_BUILD" ]] || fail 'Another update changed this app. Retry from the current copy.'
[[ "$(/usr/bin/codesign -dvvvv "$DESTINATION_APP" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')" == "$OLD_CDHASH" ]] || fail 'The installed app changed during approval.'
/usr/bin/codesign --verify --deep --strict "$DESTINATION_APP"
/bin/mv "$DESTINATION_APP" "$PREVIOUS"
SWAPPED=1
/bin/mv "$STAGED" "$DESTINATION_APP"
/usr/bin/codesign --verify --deep --strict -R "=$REQUIREMENT" "$DESTINATION_APP"
[[ "$(value "$DESTINATION_APP" CFBundleShortVersionString)" == "$EXPECTED_VERSION" && "$(value "$DESTINATION_APP" CFBundleVersion)" == "$EXPECTED_BUILD" ]]
trap - EXIT
print -r -- "Verified administrator-approved replacement at $DESTINATION_APP"
