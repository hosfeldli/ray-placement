#!/bin/zsh
set -euo pipefail

CURRENT_USER="$(id -un)"
USER_HOME_DIRECTORY="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory | awk '{print $2}')"
[[ -n "$USER_HOME_DIRECTORY" && "$USER_HOME_DIRECTORY" == /Users/* ]] || { echo "Could not safely locate your user folder."; exit 1; }
CONFIRMED="${1:-}"
SCRIPT_PATH="${0:A}"
SCRIPT_DIRECTORY="${SCRIPT_PATH:h}"
BUNDLED_APP="${SCRIPT_DIRECTORY:h:h}"
if [[ "$BUNDLED_APP" == /*.app && -f "$BUNDLED_APP/Contents/Info.plist" ]]; then
    INSTALLED_APP="$BUNDLED_APP"
elif [[ -d /Applications/Lima.app && -w /Applications ]]; then
    INSTALLED_APP="/Applications/Lima.app"
else
    INSTALLED_APP="$USER_HOME_DIRECTORY/Applications/Lima.app"
fi
APPLICATION_SUPPORT="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement"
PREFERENCES="$USER_HOME_DIRECTORY/Library/Preferences/dev.liam.rayplacement.plist"
TRASH_DIRECTORY="$USER_HOME_DIRECTORY/.Trash"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [[ "$CONFIRMED" != "--confirmed" && -t 0 ]]; then
    echo "Lima Uninstaller"
    read "REPLY?Move Lima to Trash? [y/N] "
    [[ "$REPLY" == [yY] ]] || { echo "Uninstall cancelled."; exit 0; }
fi

# Ask the running app to quit cleanly. The fallback is limited to Lima's
# process name and is only needed when the app is already unresponsive.
/usr/bin/osascript -e 'tell application id "dev.liam.lima" to quit' >/dev/null 2>&1 || true
sleep 0.8
if pgrep -x Lima >/dev/null 2>&1; then
    pkill -x Lima >/dev/null 2>&1 || true
    sleep 0.4
fi
mkdir -p "$TRASH_DIRECTORY"
if [[ -d "$INSTALLED_APP" ]]; then
    if mv "$INSTALLED_APP" "$TRASH_DIRECTORY/Lima-$STAMP.app"; then
        echo "Moved $INSTALLED_APP to Trash."
    else
        echo "Could not move $INSTALLED_APP to Trash. Move it manually from Finder." >&2
        exit 1
    fi
fi
if [[ "$CONFIRMED" != "--confirmed" && -t 0 ]]; then
    read "REMOVE_DATA?Also move Lima notes, extensions, preferences, and update files to Trash? [y/N] "
else
    REMOVE_DATA=n
fi
if [[ "$REMOVE_DATA" == [yY] ]]; then
    [[ -d "$APPLICATION_SUPPORT" ]] && mv "$APPLICATION_SUPPORT" "$TRASH_DIRECTORY/Lima-Data-$STAMP"
    [[ -f "$PREFERENCES" ]] && mv "$PREFERENCES" "$TRASH_DIRECTORY/Lima-Preferences-$STAMP.plist"
fi
echo "Lima uninstall complete."
