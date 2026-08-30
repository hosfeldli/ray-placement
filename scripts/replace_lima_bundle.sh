#!/bin/zsh
# Transactional replacement shared by the updater and source installer.
set -euo pipefail
(( $# == 4 )) || { echo 'Usage: replace_lima_bundle.sh <source-app> <destination-app> <version> <transaction-directory>' >&2; exit 2; }
SOURCE_APP="$1"
DESTINATION_APP="$2"
EXPECTED_VERSION="$3"
TRANSACTION="$4"
PARENT="${DESTINATION_APP:h}"
STAGED="$TRANSACTION/Incoming.app"
PREVIOUS="$TRANSACTION/Previous.app"
SWAPPED=0

fail() { echo "$1" >&2; exit 1; }
value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
[[ "$DESTINATION_APP" == /*.app && ! -L "$DESTINATION_APP" ]] || fail 'The installation target must be an actual app bundle, not a symbolic link.'
[[ -d "$PARENT" && -w "$PARENT" ]] || fail "The app folder is not writable: $PARENT. Replace Lima using Finder with administrator approval."
[[ "${TRANSACTION:h}" == "$PARENT" && "${TRANSACTION:t}" == .lima-install.* && -d "$TRANSACTION" && ! -L "$TRANSACTION" ]] || fail 'Invalid installation staging directory.'
[[ ! -e "$STAGED" && ! -e "$PREVIOUS" ]] || fail 'The installation staging directory is already in use.'
[[ "$(value "$SOURCE_APP" CFBundleIdentifier)" == dev.liam.lima ]] || fail 'The source is not a Lima app.'
[[ "$(value "$SOURCE_APP" CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]] || fail 'The app version does not match the requested update.'
EXPECTED_BUILD="$(value "$SOURCE_APP" CFBundleVersion)"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" || fail 'The source signature is invalid.'
if [[ -e "$DESTINATION_APP" ]]; then
    [[ -d "$DESTINATION_APP" ]] || fail 'The destination is not an application.'
    ID="$(value "$DESTINATION_APP" CFBundleIdentifier)"
    [[ "$ID" == dev.liam.lima || "$ID" == dev.liam.rayplacement ]] || fail 'Refusing to replace an unrelated app.'
fi

rollback() {
    local result=$?
    if (( result != 0 && SWAPPED )); then
        # Keep the failed incoming copy for diagnostics; never merge bundles.
        [[ ! -e "$DESTINATION_APP" ]] || mv "$DESTINATION_APP" "$TRANSACTION/Failed.app"
        [[ ! -d "$PREVIOUS" ]] || mv "$PREVIOUS" "$DESTINATION_APP"
        echo 'Installation failed; the previous app was restored.' >&2
    fi
    exit "$result"
}
trap rollback EXIT
/usr/bin/ditto "$SOURCE_APP" "$STAGED"
/usr/bin/codesign --verify --deep --strict "$STAGED"
[[ ! -d "$DESTINATION_APP" ]] || mv "$DESTINATION_APP" "$PREVIOUS"
SWAPPED=1
mv "$STAGED" "$DESTINATION_APP"
/usr/bin/codesign --verify --deep --strict "$DESTINATION_APP"
[[ "$(value "$DESTINATION_APP" CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]]
[[ "$(value "$DESTINATION_APP" CFBundleVersion)" == "$EXPECTED_BUILD" ]]
/usr/bin/cmp -s "$SOURCE_APP/Contents/MacOS/Lima" "$DESTINATION_APP/Contents/MacOS/Lima"
trap - EXIT
echo "Verified Lima $EXPECTED_VERSION ($EXPECTED_BUILD) at $DESTINATION_APP"
# The caller retains Previous.app until relaunch succeeds.
