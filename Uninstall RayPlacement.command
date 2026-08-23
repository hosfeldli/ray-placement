#!/bin/zsh
set -euo pipefail

CURRENT_USER="$(id -un)"
USER_HOME_DIRECTORY="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory | awk '{print $2}')"
[[ -n "$USER_HOME_DIRECTORY" && "$USER_HOME_DIRECTORY" == /Users/* ]] || { echo "Could not safely locate your user folder."; exit 1; }

INSTALLED_APP="$USER_HOME_DIRECTORY/Applications/RayPlacement.app"
APPLICATION_SUPPORT="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement"
PREFERENCES="$USER_HOME_DIRECTORY/Library/Preferences/dev.liam.rayplacement.plist"
TRASH_DIRECTORY="$USER_HOME_DIRECTORY/.Trash"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "RayPlacement Uninstaller"
echo
echo "This removes the app and its login item. The app is moved to Trash so it can be recovered."
echo "Your notes, extensions, preferences, and local signing identity are kept unless you explicitly remove them below."
echo
if [[ -t 0 ]]; then
    read "REPLY?Uninstall RayPlacement? [y/N] "
    [[ "$REPLY" == [yY] ]] || { echo "Uninstall cancelled."; exit 0; }
fi

pkill -x RayPlacement >/dev/null 2>&1 || true
if [[ -x "$INSTALLED_APP/Contents/MacOS/RayPlacement" ]]; then
    "$INSTALLED_APP/Contents/MacOS/RayPlacement" --unregister-login-item-and-quit >/dev/null 2>&1 || true
fi
pkill -x RayPlacement >/dev/null 2>&1 || true

mkdir -p "$TRASH_DIRECTORY"
if [[ -d "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$TRASH_DIRECTORY/RayPlacement-$STAMP.app"
    echo "Moved the app to Trash."
else
    echo "RayPlacement was not installed in $USER_HOME_DIRECTORY/Applications."
fi

REMOVE_DATA=n
if [[ -t 0 ]]; then
    echo
    read "REMOVE_DATA?Also move all RayPlacement notes, extensions, preferences, update files, and signing identity to Trash? [y/N] "
fi

if [[ "$REMOVE_DATA" == [yY] ]]; then
    CERTIFICATE="$APPLICATION_SUPPORT/Signing/RayPlacementLocalSigning.cer"
    if [[ -f "$CERTIFICATE" ]]; then
        security remove-trusted-cert "$CERTIFICATE" >/dev/null 2>&1 || true
        security delete-certificate -c "RayPlacement Local Code Signing" "$USER_HOME_DIRECTORY/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
    fi
    [[ -d "$APPLICATION_SUPPORT" ]] && mv "$APPLICATION_SUPPORT" "$TRASH_DIRECTORY/RayPlacement-Data-$STAMP"
    [[ -f "$PREFERENCES" ]] && mv "$PREFERENCES" "$TRASH_DIRECTORY/RayPlacement-Preferences-$STAMP.plist"
    echo "Moved RayPlacement's local data and signing files to Trash."
else
    echo "Kept your local notes, extensions, preferences, and signing identity."
fi

echo "Uninstall complete."
echo "You can close this window."
