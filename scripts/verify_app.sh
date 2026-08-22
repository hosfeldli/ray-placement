#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_DIRECTORY="${1:-$PROJECT_DIRECTORY/build/RayPlacement.app}"
BINARY="$APP_DIRECTORY/Contents/MacOS/RayPlacement"

test -d "$APP_DIRECTORY"
test -x "$BINARY"
test -f "$APP_DIRECTORY/Contents/Resources/RayPlacement.icns"
test -x "$APP_DIRECTORY/Contents/Resources/Tools/harper-cli"
test -x "$APP_DIRECTORY/Contents/Resources/CoEdit/node"
test -f "$APP_DIRECTORY/Contents/Resources/CoEdit/runner.mjs"
test -f "$APP_DIRECTORY/Contents/Resources/CoEdit/model/encoder_model.onnx"
test -f "$APP_DIRECTORY/Contents/Resources/CoEdit/model/decoder_model.onnx"
test -f "$APP_DIRECTORY/Contents/Resources/CoEdit/model/decoder_with_past_model.onnx"
test -x "$APP_DIRECTORY/Contents/Resources/Qwen/runtime/llama-cli"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/runtime/LICENSE"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/Qwen3-1.7B-Q8_0.gguf"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/MODEL_LICENSE"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/REVISION"
test -f "$APP_DIRECTORY/Contents/Resources/Licenses/Harper-LICENSE"
plutil -lint "$APP_DIRECTORY/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$APP_DIRECTORY"

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIRECTORY/Contents/Info.plist")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIRECTORY/Contents/Info.plist")"
[[ "$BUNDLE_IDENTIFIER" == "dev.liam.rayplacement" ]]
[[ "$MINIMUM_SYSTEM" == "13.0" ]]
file "$BINARY" | grep -q "Mach-O 64-bit executable arm64"
file "$APP_DIRECTORY/Contents/Resources/Tools/harper-cli" | grep -q "Mach-O 64-bit executable arm64"
file "$APP_DIRECTORY/Contents/Resources/CoEdit/node" | grep -q "Mach-O 64-bit executable arm64"
file "$APP_DIRECTORY/Contents/Resources/Qwen/runtime/llama-cli" | grep -q "Mach-O 64-bit executable arm64"

COEDIT_RESULT="$(printf 'This are a sentence with bad grammer.' | \
    "$APP_DIRECTORY/Contents/Resources/CoEdit/node" \
    "$APP_DIRECTORY/Contents/Resources/CoEdit/runner.mjs" \
    "$APP_DIRECTORY/Contents/Resources/CoEdit/model")"
[[ "$COEDIT_RESULT" == "This is a sentence with bad grammar." ]]

QWEN_RUNTIME="$APP_DIRECTORY/Contents/Resources/Qwen/runtime"
QWEN_MODEL="$APP_DIRECTORY/Contents/Resources/Qwen/Qwen3-1.7B-Q8_0.gguf"
QWEN_CONSOLE="$(
    "$QWEN_RUNTIME/llama-cli" \
        -m "$QWEN_MODEL" \
        --conversation \
        --single-turn \
        --reasoning off \
        --system-prompt "You are an exacting English proofreading engine. Correct every spelling, grammar, word-choice, and punctuation error. Preserve the intended meaning. Return only the fully corrected text, with no explanation." \
        --prompt "Hi; whot where you thinking, about" \
        --simple-io \
        --no-display-prompt \
        --log-disable \
        --predict 128 \
        --temp 0 \
        --ctx-size 2048
)"
QWEN_RESULT="$(printf '%s\n' "$QWEN_CONSOLE" | awk '/^> Hi; whot where you thinking, about$/{getline; print; exit}')"
[[ "$QWEN_RESULT" == "Hi; what are you thinking about?" || "$QWEN_RESULT" == "Hi, what are you thinking about?" ]]

echo "Verified RayPlacement.app"
