#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_DIRECTORY="${1:-$PROJECT_DIRECTORY/dist}"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/rayplacement-update.XXXXXX")"

cleanup() {
    [[ "$TEMP_DIRECTORY" == "${TMPDIR%/}"/rayplacement-update.* ]] && rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

STAGED_SOURCE="$TEMP_DIRECTORY/LiamFlowUpdate"
PREBUILT_APP="$PROJECT_DIRECTORY/build/LiamFlow.app"
mkdir -p "$STAGED_SOURCE" "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
rsync -a \
    --exclude .git/ \
    --exclude .github/ \
    --exclude .build/ \
    --exclude build/ \
    --exclude dist/ \
    --exclude Downloads/ \
    --exclude Packaging/Vendor/Whisper/ \
    --exclude Packaging/Vendor/CoEdit/ \
    --exclude Packaging/Vendor/Qwen/ \
    --exclude .DS_Store \
    "$PROJECT_DIRECTORY/" "$STAGED_SOURCE/"

ARCHIVE="$OUTPUT_DIRECTORY/LiamFlow-Update.zip"
rm -f "$ARCHIVE" "$OUTPUT_DIRECTORY/LiamFlow-Update.sha256"

# Local grammar correction must be in every update kit. Whisper's large model
# is restored from the already-installed app by apply_downloaded_update.sh.
test -f "$STAGED_SOURCE/Packaging/Vendor/Harper/harper-cli"
test -f "$STAGED_SOURCE/Packaging/Vendor/PythonGrammar/grammar_check.py"
test -d "$STAGED_SOURCE/Packaging/Vendor/PythonGrammar/site-packages/spellchecker"
test -d "$PREBUILT_APP"
mkdir -p "$STAGED_SOURCE/Prebuilt"
ditto "$PREBUILT_APP" "$STAGED_SOURCE/Prebuilt/LiamFlow.app"
(
    cd "$TEMP_DIRECTORY"
    ditto -c -k --sequesterRsrc --keepParent LiamFlowUpdate "$ARCHIVE"
)
(
    cd "$OUTPUT_DIRECTORY"
    shasum -a 256 "$(basename "$ARCHIVE")" > LiamFlow-Update.sha256
)
echo "Created: $ARCHIVE"
