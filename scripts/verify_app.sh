#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_DIRECTORY="${1:-$PROJECT_DIRECTORY/build/RayPlacement.app}"
BINARY="$APP_DIRECTORY/Contents/MacOS/RayPlacement"

test -d "$APP_DIRECTORY"
test -x "$BINARY"
test -f "$APP_DIRECTORY/Contents/Resources/RayPlacement.icns"
test -x "$APP_DIRECTORY/Contents/Resources/Qwen/runtime/llama-cli"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/runtime/LICENSE"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/Qwen3-1.7B-Q8_0.gguf"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/MODEL_LICENSE"
test -f "$APP_DIRECTORY/Contents/Resources/Qwen/REVISION"
test ! -d "$APP_DIRECTORY/Contents/Resources/Qwen/ModelParts"
test ! -e "$APP_DIRECTORY/Contents/Resources/CoEdit"
test ! -e "$APP_DIRECTORY/Contents/Resources/Tools/harper-cli"
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
[[ "$VERSION" == "1.10.1" ]]
[[ "$BUILD_NUMBER" == "17" ]]
[[ -n "$MICROPHONE_DESCRIPTION" ]]
[[ -n "$SPEECH_DESCRIPTION" ]]
if [[ "${RAYPLACEMENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
    DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP_DIRECTORY" 2>&1)"
    if [[ "$DESIGNATED_REQUIREMENT" == *"cdhash"* ]]; then
        echo "The app is ad-hoc signed; its Accessibility identity will change after rebuilds."
        exit 1
    fi
fi
file "$BINARY" | grep -q "Mach-O 64-bit executable arm64"
file "$APP_DIRECTORY/Contents/Resources/Qwen/runtime/llama-cli" | grep -q "Mach-O 64-bit executable arm64"
echo "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a  $APP_DIRECTORY/Contents/Resources/Qwen/Qwen3-1.7B-Q8_0.gguf" | shasum -a 256 -c - >/dev/null
echo "1895313a209f70c745ccd8d1946c2c81c84e87ac50564ddb3dd4adb376dd7a52  $APP_DIRECTORY/Contents/Resources/Qwen/runtime/llama-cli" | shasum -a 256 -c - >/dev/null

QWEN_RUNTIME="$APP_DIRECTORY/Contents/Resources/Qwen/runtime"
QWEN_MODEL="$APP_DIRECTORY/Contents/Resources/Qwen/Qwen3-1.7B-Q8_0.gguf"
if [[ "${RAYPLACEMENT_VERIFY_MODEL_RUNTIME:-0}" == "1" && "${RAYPLACEMENT_VERIFY_MODEL_QUALITY:-0}" != "1" ]]; then
QWEN_HEALTH_CONSOLE="$(
    "$QWEN_RUNTIME/llama-cli" \
        -m "$QWEN_MODEL" \
        --conversation \
        --single-turn \
        --reasoning off \
        --system-prompt "Reply briefly." \
        --prompt "Health check." \
        --simple-io \
        --no-display-prompt \
        --log-disable \
        --predict 1 \
        --temp 0 \
        --ctx-size 1024 \
        --threads 1 \
        --threads-batch 1 \
        --batch-size 128 \
        --ubatch-size 64 \
        --prio -1 \
        --prio-batch 0 \
        --gpu-layers 0 \
        --no-warmup
)"
[[ -n "$QWEN_HEALTH_CONSOLE" ]]
fi

if [[ "${RAYPLACEMENT_VERIFY_MODEL_QUALITY:-0}" == "1" ]]; then
for QUALITY_ATTEMPT in 1 2; do
QWEN_CONSOLE="$(
    "$QWEN_RUNTIME/llama-cli" \
        -m "$QWEN_MODEL" \
        --conversation \
        --single-turn \
        --reasoning off \
        --system-prompt "You are an exacting English copy editor. The user's text may contain several interacting mistakes. Silently review the entire passage twice: first for spelling and word choice, then for grammar, agreement, tense, sentence structure, capitalization, and punctuation. Correct every error you can identify, not only the first or most obvious one. Repair fragments, missing words, wrong homophones, and dangling prepositions when the intended meaning is clear. Do not preserve a mistake merely because it could be read as slang. Return only the fully corrected passage with no explanation, labels, preamble, alternatives, or quotation marks. Examples: Input: u really is a great Output: You really are great. Input: Hi; whot where you thinking, about Output: Hi, what were you thinking about? Input: Their going too meet us tommorow, but nobody know where. Output: They're going to meet us tomorrow, but nobody knows where. User correction requirements: Preserve names, product terms, acronyms, Markdown, and intentional capitalization. Use clear, concise, professional English." \
        --prompt "Hi; whot where you thinking, about" \
        --simple-io \
        --no-display-prompt \
        --log-disable \
        --predict 512 \
        --temp 0.2 \
        --ctx-size 8192 \
        --threads 1 \
        --threads-batch 1 \
        --batch-size 128 \
        --ubatch-size 64 \
        --prio -1 \
        --prio-batch 0 \
        --gpu-layers 0 \
        --no-warmup
)"
QWEN_RESULT="$(printf '%s\n' "$QWEN_CONSOLE" | awk '/^> Hi; whot where you thinking, about$/{getline; print; exit}')"
QWEN_RESULT_LOWER="${QWEN_RESULT:l}"
if [[ "$QWEN_RESULT_LOWER" != *"whot"* \
    && "$QWEN_RESULT_LOWER" != *"where you"* \
    && "$QWEN_RESULT_LOWER" == *"thinking about?"* ]]; then
    break
fi
if [[ "$QUALITY_ATTEMPT" == "2" ]]; then
    echo "Qwen grammar quality check failed: $QWEN_RESULT" >&2
    exit 1
fi
sleep 2
done

sleep 2

QWEN_SUMMARY_PROMPT=$'# Notes to summarize\n\nMeeting notes: Alice decided to ship Friday. Bob will review the release. Risk: incomplete tests.\n\n# Required output\nWrite a useful summary with complete Markdown bullet points.'
for QUALITY_ATTEMPT in 1 2; do
QWEN_SUMMARY_CONSOLE="$(
    "$QWEN_RUNTIME/llama-cli" \
        -m "$QWEN_MODEL" \
        --conversation \
        --single-turn \
        --reasoning off \
        --system-prompt "Combine the supplied notes into one accurate Markdown summary. Use the headings Overview, Decisions, Action Items, Risks, and Open Questions when relevant. Remove repetition, preserve names and dates, and never invent facts. Return only the finished summary with complete Markdown sentences." \
        --prompt "$QWEN_SUMMARY_PROMPT" \
        --simple-io \
        --no-display-prompt \
        --log-disable \
        --predict 256 \
        --temp 0 \
        --ctx-size 2048 \
        --threads 1 \
        --threads-batch 1 \
        --batch-size 128 \
        --ubatch-size 64 \
        --prio -1 \
        --prio-batch 0 \
        --gpu-layers 0 \
        --no-warmup
)"
QWEN_SUMMARY_RESULT="$(printf '%s\n' "$QWEN_SUMMARY_CONSOLE" | awk '
    !collecting && /^Write a useful summary with complete Markdown bullet points\.$/ { collecting=1; next }
    collecting && /^\[ Prompt:/ { exit }
    collecting { print }
')"
QWEN_SUMMARY_RESULT_LOWER="${QWEN_SUMMARY_RESULT:l}"
if [[ "$QWEN_SUMMARY_RESULT" == *"Alice"* \
    && "$QWEN_SUMMARY_RESULT" == *"Bob"* \
    && "$QWEN_SUMMARY_RESULT" == *"Friday"* \
    && "$QWEN_SUMMARY_RESULT_LOWER" == *"incomplete"* \
    && "$QWEN_SUMMARY_RESULT_LOWER" == *"tests"* ]]; then
    break
fi
if [[ "$QUALITY_ATTEMPT" == "2" ]]; then
    echo "Qwen summary quality check failed: $QWEN_SUMMARY_RESULT" >&2
    exit 1
fi
sleep 2
done
fi

echo "Verified RayPlacement.app"
