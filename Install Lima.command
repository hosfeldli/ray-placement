#!/bin/zsh
# Optional installer for a prebuilt checkout. The public DMG remains drag-to-install.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
SOURCE_APP="$SCRIPT_DIRECTORY/build/Lima.app"
[[ -d "$SOURCE_APP" ]] || SOURCE_APP="$SCRIPT_DIRECTORY/Lima.app"
DESTINATION="${1:-/Applications/Lima.app}"
USER_APPLICATION="${HOME:?}/Applications/Lima.app"
if (( $# == 0 )); then
    if [[ -d /Applications/Lima.app && -d "$USER_APPLICATION" ]]; then
        echo "Two installed copies exist. Pass the exact app path to replace, or use Finder to replace the intended copy. Neither has been changed." >&2
        exit 1
    elif [[ -d "$USER_APPLICATION" ]]; then
        DESTINATION="$USER_APPLICATION"
    fi
fi
[[ -d "$SOURCE_APP" ]] || { echo 'Download Lima.dmg from https://www.liamhosfeld.com and drag Lima into Applications. This installer requires a prebuilt Lima.app; it does not compile source or change Keychain trust.' >&2; exit 1; }
[[ "$DESTINATION" == /*.app && -w "${DESTINATION:h}" ]] || { echo 'Open the DMG in Finder and drag Lima into Applications, approving administrator access if requested.' >&2; exit 1; }
if pgrep -x Lima >/dev/null; then
    echo 'Quit Lima before installing, then run this installer again.' >&2
    exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
"$SCRIPT_DIRECTORY/scripts/verify_liamflow_app.sh" "$SOURCE_APP"
TRANSACTION="$(mktemp -d "${DESTINATION:h}/.lima-install.XXXXXX")"
/bin/zsh "$SCRIPT_DIRECTORY/scripts/replace_lima_bundle.sh" "$SOURCE_APP" "$DESTINATION" "$VERSION" "$TRANSACTION"
echo "Previous copy (if any): $TRANSACTION/Previous.app"
[[ "${RAYPLACEMENT_SKIP_LAUNCH:-0}" == 1 ]] || /usr/bin/open -n "$DESTINATION"
