#!/bin/zsh
set -euo pipefail

CURRENT_USER="$(id -un)"
USER_HOME_DIRECTORY="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory | awk '{print $2}')"
[[ -n "$USER_HOME_DIRECTORY" && "$USER_HOME_DIRECTORY" == /Users/* ]] || { echo "Could not safely locate your user folder."; exit 1; }
CONFIRMED="${1:-}"
INSTALLED_APP="$USER_HOME_DIRECTORY/Applications/LiamFlow.app"
APPLICATION_SUPPORT="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement"
PREFERENCES="$USER_HOME_DIRECTORY/Library/Preferences/dev.liam.rayplacement.plist"
TRASH_DIRECTORY="$USER_HOME_DIRECTORY/.Trash"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [[ "$CONFIRMED" != "--confirmed" && -t 0 ]]; then
    echo "LiamFlow Uninstaller"
    read "REPLY?Move LiamFlow to Trash? [y/N] "
    [[ "$REPLY" == [yY] ]] || { echo "Uninstall cancelled."; exit 0; }
fi

pkill -x LiamFlow >/dev/null 2>&1 || true
mkdir -p "$TRASH_DIRECTORY"
if [[ -d "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$TRASH_DIRECTORY/LiamFlow-$STAMP.app"
    echo "Moved LiamFlow to Trash."
fi
if [[ "$CONFIRMED" != "--confirmed" && -t 0 ]]; then
    read "REMOVE_DATA?Also move LiamFlow notes, extensions, preferences, and update files to Trash? [y/N] "
else
    REMOVE_DATA=n
fi
if [[ "$REMOVE_DATA" == [yY] ]]; then
    [[ -d "$APPLICATION_SUPPORT" ]] && mv "$APPLICATION_SUPPORT" "$TRASH_DIRECTORY/LiamFlow-Data-$STAMP"
    [[ -f "$PREFERENCES" ]] && mv "$PREFERENCES" "$TRASH_DIRECTORY/LiamFlow-Preferences-$STAMP.plist"
fi
echo "LiamFlow uninstall complete."
