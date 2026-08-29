#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_DIRECTORY="${1:-$PROJECT_DIRECTORY/build/RayPlacement.app}"
BINARY="$APP_DIRECTORY/Contents/MacOS/RayPlacement"
RESOURCES="$APP_DIRECTORY/Contents/Resources"

test -d "$APP_DIRECTORY"
test -x "$BINARY"
test -f "$RESOURCES/RayPlacement.icns"
test ! -e "$RESOURCES/Qwen"
test ! -e "$RESOURCES/CoEdit"
test -x "$RESOURCES/Tools/harper-cli"
test -x "$RESOURCES/Tools/PythonGrammar/grammar_check.py"
test -d "$RESOURCES/Tools/PythonGrammar/site-packages/spellchecker"
test -x "$RESOURCES/Whisper/runtime/whisper-cli"
test -f "$RESOURCES/Whisper/model/ggml-small.en-tdrz.bin"
test -f "$RESOURCES/Whisper/LICENSE"
test -f "$RESOURCES/Whisper/REVISION"
test -f "$RESOURCES/Documentation/EXTENSIONS.md"
test -f "$RESOURCES/Documentation/EXTENSION_AUTHORING_FOR_AI.md"
test -f "$RESOURCES/Documentation/extension-manifest.schema.json"
test -f "$RESOURCES/Emoji/emoji-test.txt"
[[ "$(/usr/bin/grep -c '; fully-qualified' "$RESOURCES/Emoji/emoji-test.txt")" -ge 3900 ]]
plutil -lint "$APP_DIRECTORY/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$APP_DIRECTORY"

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIRECTORY/Contents/Info.plist")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIRECTORY/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIRECTORY/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIRECTORY/Contents/Info.plist")"
MICROPHONE_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP_DIRECTORY/Contents/Info.plist")"
SPEECH_DESCRIPTION="$(/usr/libexec/PlistBuddy -c 'Print :NSSpeechRecognitionUsageDescription' "$APP_DIRECTORY/Contents/Info.plist")"
[[ "$BUNDLE_IDENTIFIER" == "dev.liam.rayplacement" ]]
[[ "$MINIMUM_SYSTEM" == "13.0" ]]
[[ "$VERSION" == "1.18.0" ]]
[[ "$BUILD_NUMBER" == "27" ]]
[[ -n "$MICROPHONE_DESCRIPTION" ]]
[[ -n "$SPEECH_DESCRIPTION" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$APP_DIRECTORY/Contents/Info.plist")" ]]
if [[ "${RAYPLACEMENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
    DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP_DIRECTORY" 2>&1)"
    if [[ "$DESIGNATED_REQUIREMENT" == *"cdhash"* ]]; then
        echo "The app is ad-hoc signed; its Accessibility identity will change after rebuilds."
        exit 1
    fi
fi

file "$BINARY" | grep -q "Mach-O 64-bit executable arm64"
file "$RESOURCES/Tools/harper-cli" | grep -q "Mach-O 64-bit executable arm64"
file "$RESOURCES/Whisper/runtime/whisper-cli" | grep -q "Mach-O 64-bit executable arm64"
echo "ceac3ec06d1d98ef71aec665283564631055fd6129b79d8e1be4f9cc33cc54b4  $RESOURCES/Whisper/model/ggml-small.en-tdrz.bin" | shasum -a 256 -c - >/dev/null
echo "7bc894dd031cdb777a68d07a567ddc37a702b70ccd26adccf20f85e6f6e6cecc  $RESOURCES/Whisper/runtime/whisper-cli" | shasum -a 256 -c - >/dev/null
"$RESOURCES/Whisper/runtime/whisper-cli" --version | grep -q "1.9.1"

GRAMMAR_RESULT="$(printf '%s' '{"text":"Hi; whot where you thinking, about","preserve":"RayPlacement VS Code Postman EDI"}' | /usr/bin/python3 "$RESOURCES/Tools/PythonGrammar/grammar_check.py")"
[[ "$GRAMMAR_RESULT" == "Hi, what were you thinking about?" ]]
SECOND_GRAMMAR_RESULT="$(printf '%s' '{"text":"u really is a great","preserve":"RayPlacement"}' | /usr/bin/python3 "$RESOURCES/Tools/PythonGrammar/grammar_check.py")"
[[ "$SECOND_GRAMMAR_RESULT" == "You really are great." ]]

HARPER_INPUT='I has an apple.'
HARPER_OUTPUT="$(printf '%s' "$HARPER_INPUT" | "$RESOURCES/Tools/harper-cli" --no-color lint --format json --quiet)" || HARPER_STATUS=$?
[[ "${HARPER_STATUS:-0}" == "0" || "${HARPER_STATUS:-0}" == "1" ]]
[[ "$HARPER_OUTPUT" == *"have"* ]]

echo "Verified RayPlacement.app"
