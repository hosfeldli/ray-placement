#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_DIRECTORY="${1:-$PROJECT_DIRECTORY/build/Lima.app}"
RESOURCES="$APP_DIRECTORY/Contents/Resources"
BINARY="$APP_DIRECTORY/Contents/MacOS/Lima"
SOURCE_INFO="$PROJECT_DIRECTORY/Packaging/Info.plist"

require() {
    local description="$1"
    shift
    "$@" || { echo "Verification failed: $description" >&2; exit 1; }
}

require "Lima.app is missing" test -d "$APP_DIRECTORY"
require "the Lima executable is missing" test -x "$BINARY"
require "the app icon is missing" test -f "$RESOURCES/RayPlacement.icns"
require "the Harper executable is missing" test -x "$RESOURCES/Tools/harper-cli"
require "the Python grammar checker is missing" test -x "$RESOURCES/Tools/PythonGrammar/grammar_check.py"
require "the spelling resources are missing" test -d "$RESOURCES/Tools/PythonGrammar/site-packages/spellchecker"
require "the Whisper runtime is missing" test -x "$RESOURCES/Whisper/runtime/whisper-cli"
if [[ "${RAYPLACEMENT_MODEL_FREE_UPDATE:-0}" != "1" ]]; then
    require "the local dictation model is missing" test -f "$RESOURCES/Whisper/model/ggml-small.en-tdrz.bin"
    [[ "$(shasum -a 256 "$RESOURCES/Whisper/model/ggml-small.en-tdrz.bin" | awk '{print $1}')" == ceac3ec06d1d98ef71aec665283564631055fd6129b79d8e1be4f9cc33cc54b4 ]] || { echo 'Verification failed: the dictation model checksum is incorrect' >&2; exit 1; }
fi
require "the extension documentation is missing" test -f "$RESOURCES/Documentation/EXTENSIONS.md"
require "the emoji data is missing" test -f "$RESOURCES/Emoji/emoji-test.txt"
require "the bundled extensions are missing" test -d "$RESOURCES/BundledExtensions"
require "the bundled uninstaller is missing" test -x "$RESOURCES/Uninstall Lima.command"
require "the protected-folder updater is missing" test -f "$RESOURCES/Updater/approved_lima_replacement.sh"
require "the administrator approval dialog is missing" test -f "$RESOURCES/Updater/authorize_lima_update.applescript"
require "Info.plist is invalid" plutil -lint "$APP_DIRECTORY/Contents/Info.plist"
require "the app signature is invalid" codesign --verify --deep --strict "$APP_DIRECTORY"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_DIRECTORY/Contents/Info.plist")" == "Lima" ]] || { echo "Verification failed: the display name is not Lima" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DIRECTORY/Contents/Info.plist")" == "Lima" ]] || { echo "Verification failed: the executable name is not Lima" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIRECTORY/Contents/Info.plist")" == "dev.liam.lima" ]] || { echo "Verification failed: the bundle identifier is incorrect" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP_DIRECTORY/Contents/Info.plist")" == "false" ]] || { echo "Verification failed: Lima is not configured to appear in the Dock" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIRECTORY/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_INFO")" ]] || { echo "Verification failed: the app version does not match the release version" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIRECTORY/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_INFO")" ]] || { echo "Verification failed: the app build number does not match the release build" >&2; exit 1; }
if [[ "${RAYPLACEMENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
    DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP_DIRECTORY" 2>&1)"
    [[ "$DESIGNATED_REQUIREMENT" != *"cdhash"* ]] || { echo "Verification failed: Lima is ad-hoc signed and would lose Accessibility approval on update" >&2; exit 1; }
fi
require "the Lima executable is not Apple-silicon native" sh -c "file '$BINARY' | grep -q 'Mach-O 64-bit executable arm64'"
require "the Harper executable is not Apple-silicon native" sh -c "file '$RESOURCES/Tools/harper-cli' | grep -q 'Mach-O 64-bit executable arm64'"
require "the Whisper runtime is not Apple-silicon native" sh -c "file '$RESOURCES/Whisper/runtime/whisper-cli' | grep -q 'Mach-O 64-bit executable arm64'"
echo "Verified Lima.app"
