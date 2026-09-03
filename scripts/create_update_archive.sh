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

STAGED_SOURCE="$TEMP_DIRECTORY/LimaUpdate"
PREBUILT_APP="$PROJECT_DIRECTORY/build/Lima.app"
mkdir -p "$STAGED_SOURCE" "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
rsync -a \
    --exclude .git/ \
    --exclude .github/ \
    --exclude .build/ \
    --exclude build/ \
    --exclude dist/ \
    --exclude Downloads/ \
    --exclude 'Packaging/Vendor/Whisper/**' \
    --exclude 'Packaging/Vendor/Whisper/model/**' \
    --exclude 'Packaging/Vendor/CoEdit/**' \
    --exclude 'Packaging/Vendor/Qwen/**' \
    --exclude .DS_Store \
    "$PROJECT_DIRECTORY/" "$STAGED_SOURCE/"

ARCHIVE="$OUTPUT_DIRECTORY/Lima-Update.zip"
rm -f "$ARCHIVE" "$OUTPUT_DIRECTORY/Lima-Update.sha256"

# Local grammar correction must be in every update kit. Whisper's large model
# is restored from the already-installed app by apply_downloaded_update.sh.
test -f "$STAGED_SOURCE/Packaging/Vendor/Harper/harper-cli"
test -f "$STAGED_SOURCE/Packaging/Vendor/PythonGrammar/grammar_check.py"
test -d "$STAGED_SOURCE/Packaging/Vendor/PythonGrammar/site-packages/spellchecker"
test -d "$PREBUILT_APP"
# Update archives must never contain the 465 MB Whisper model. The updater
# reuses the checksum-verified model already on the Mac. Refuse an unsafe local
# packaging order instead of silently publishing an oversized update.
test ! -f "$PREBUILT_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin" || {
    echo "Refusing to create an oversized update. Repackage with RAYPLACEMENT_MODEL_FREE_UPDATE=1 first." >&2
    exit 1
}
mkdir -p "$STAGED_SOURCE/Prebuilt"
ditto "$PREBUILT_APP" "$STAGED_SOURCE/Prebuilt/Lima.app"
(
    cd "$TEMP_DIRECTORY"
    ditto -c -k --sequesterRsrc --keepParent LimaUpdate "$ARCHIVE"
)
ARCHIVE_BYTES="$(stat -f %z "$ARCHIVE")"
if (( ARCHIVE_BYTES <= 0 || ARCHIVE_BYTES > 100 * 1024 * 1024 )); then
    rm -f "$ARCHIVE"
    echo "Refusing to publish an update archive larger than Lima's 100 MB safety limit." >&2
    exit 1
fi
(
    cd "$OUTPUT_DIRECTORY"
    shasum -a 256 "$(basename "$ARCHIVE")" > Lima-Update.sha256
)
echo "Created: $ARCHIVE"
