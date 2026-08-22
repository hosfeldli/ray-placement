#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIRECTORY/build/RayPlacement.app"
SOURCE_EXTENSIONS_DIRECTORY="$SCRIPT_DIRECTORY/Extensions"
CURRENT_USER="$(id -un)"
USER_HOME_DIRECTORY="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory | awk '{print $2}')"

if [[ -z "$USER_HOME_DIRECTORY" || "$USER_HOME_DIRECTORY" != /Users/* ]]; then
    echo "Could not safely locate your user folder."
    exit 1
fi

USER_APPLICATIONS_DIRECTORY="$USER_HOME_DIRECTORY/Applications"
INSTALLED_APP="$USER_APPLICATIONS_DIRECTORY/RayPlacement.app"
EXTENSIONS_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Extensions"
LEGACY_WRITING_MANIFEST="$EXTENSIONS_DIRECTORY/manifest.json"

if [[ ! -d "$SOURCE_APP" || ! -d "$SOURCE_EXTENSIONS_DIRECTORY" ]]; then
    echo "The RayPlacement app or bundled extensions are missing from this folder."
    exit 1
fi

codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$USER_APPLICATIONS_DIRECTORY" "$EXTENSIONS_DIRECTORY"
pkill -x RayPlacement >/dev/null 2>&1 || true

if [[ -d "$INSTALLED_APP" ]]; then
    rm -rf "$INSTALLED_APP"
fi
if [[ -f "$LEGACY_WRITING_MANIFEST" ]] && grep -q '"id"[[:space:]]*:[[:space:]]*"local.writing-tools"' "$LEGACY_WRITING_MANIFEST"; then
    mv "$LEGACY_WRITING_MANIFEST" "$EXTENSIONS_DIRECTORY/writing-tools-legacy-manifest.backup"
fi

ditto "$SOURCE_APP" "$INSTALLED_APP"
for SOURCE_EXTENSION in "$SOURCE_EXTENSIONS_DIRECTORY"/*; do
    [[ -d "$SOURCE_EXTENSION" && -f "$SOURCE_EXTENSION/manifest.json" ]] || continue
    EXTENSION_NAME="$(basename "$SOURCE_EXTENSION")"
    INSTALLED_EXTENSION="$EXTENSIONS_DIRECTORY/$EXTENSION_NAME"
    if [[ -d "$INSTALLED_EXTENSION" ]]; then
        rm -rf "$INSTALLED_EXTENSION"
    fi
    ditto "$SOURCE_EXTENSION" "$INSTALLED_EXTENSION"
done
codesign --verify --deep --strict "$INSTALLED_APP"
open "$INSTALLED_APP"

echo
echo "RayPlacement, Notes, Writing Tools, and VS Code Directories are installed."
echo "App: $INSTALLED_APP"
echo "Plain-text paste: Control-Option-V"
echo "Writing check: Control-Option-G"
echo "Configure any extension shortcut in Settings → Extensions."
echo "Choose AI and dictation limits in Settings → Performance."
echo "Check selected-text access in Settings → General → Accessibility."
echo
echo "You can close this window."
