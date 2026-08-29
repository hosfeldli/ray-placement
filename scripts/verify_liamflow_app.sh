#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_DIRECTORY="${1:-$PROJECT_DIRECTORY/build/LiamFlow.app}"
RESOURCES="$APP_DIRECTORY/Contents/Resources"
BINARY="$APP_DIRECTORY/Contents/MacOS/LiamFlow"
SOURCE_INFO="$PROJECT_DIRECTORY/Packaging/Info.plist"

test -d "$APP_DIRECTORY"
test -x "$BINARY"
test -f "$RESOURCES/RayPlacement.icns"
test -x "$RESOURCES/Tools/harper-cli"
test -x "$RESOURCES/Tools/PythonGrammar/grammar_check.py"
test -d "$RESOURCES/Tools/PythonGrammar/site-packages/spellchecker"
test -x "$RESOURCES/Whisper/runtime/whisper-cli"
if [[ "${RAYPLACEMENT_MODEL_FREE_UPDATE:-0}" != "1" ]]; then
    test -f "$RESOURCES/Whisper/model/ggml-small.en-tdrz.bin"
fi
test -f "$RESOURCES/Documentation/EXTENSIONS.md"
test -f "$RESOURCES/Emoji/emoji-test.txt"
test -x "$RESOURCES/Uninstall LiamFlow.command"
plutil -lint "$APP_DIRECTORY/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$APP_DIRECTORY"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_DIRECTORY/Contents/Info.plist")" == "LiamFlow" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DIRECTORY/Contents/Info.plist")" == "LiamFlow" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIRECTORY/Contents/Info.plist")" == "dev.liam.liamflow" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIRECTORY/Contents/Info.plist")" == "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_INFO")" ]]
file "$BINARY" | grep -q "Mach-O 64-bit executable arm64"
file "$RESOURCES/Tools/harper-cli" | grep -q "Mach-O 64-bit executable arm64"
file "$RESOURCES/Whisper/runtime/whisper-cli" | grep -q "Mach-O 64-bit executable arm64"
echo "Verified LiamFlow.app"
