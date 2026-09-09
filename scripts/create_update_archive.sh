#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
source "$SCRIPT_DIRECTORY/release_config.sh"
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
# The update archive is deliberately data-only: it contains the candidate
# signed app and no source tree, shell scripts, build files, or updater logic.
mkdir -p "$STAGED_SOURCE/Prebuilt"
test -d "$PREBUILT_APP"
ditto "$PREBUILT_APP" "$STAGED_SOURCE/Prebuilt/Lima.app"

ARCHIVE="$OUTPUT_DIRECTORY/Lima-Update.zip"
rm -f "$ARCHIVE" "$OUTPUT_DIRECTORY/Lima-Update.sha256"

# The candidate app is self-contained for the update verifier. Large optional
# model data is intentionally excluded by the packaging step before this script.
# Update archives must never contain the 465 MB Whisper model. The installed
# app accesses the validated per-user model cache after replacement.
test ! -f "$PREBUILT_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin" || {
    echo "Refusing to create an oversized update. Repackage with RAYPLACEMENT_MODEL_FREE_UPDATE=1 first." >&2
    exit 1
}
(
    cd "$TEMP_DIRECTORY"
    ditto -c -k --norsrc --keepParent LimaUpdate "$ARCHIVE"
)
ARCHIVE_BYTES="$(stat -f %z "$ARCHIVE")"
if (( ARCHIVE_BYTES <= 0 || ARCHIVE_BYTES > LIMA_RELEASE_MAX_UPDATE_BYTES )); then
    rm -f "$ARCHIVE"
    echo "Refusing to publish an update archive larger than the configured $LIMA_RELEASE_MAX_UPDATE_BYTES-byte safety limit." >&2
    exit 1
fi
(
    cd "$OUTPUT_DIRECTORY"
    shasum -a 256 "$(basename "$ARCHIVE")" > Lima-Update.sha256
)
echo "Created: $ARCHIVE"
