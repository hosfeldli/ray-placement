#!/bin/zsh
# Create the normal application archive consumed by Sparkle's updater. This is
# deliberately separate from Lima-Update.zip, whose LimaUpdate/Prebuilt layout
# is owned by the legacy signed-custom updater.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
source "$SCRIPT_DIRECTORY/release_config.sh"
OUTPUT_DIRECTORY="${1:-$PROJECT_DIRECTORY/dist}"
APP_DIRECTORY="${2:-$PROJECT_DIRECTORY/build/Lima.app}"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
ARCHIVE="$OUTPUT_DIRECTORY/Lima-Sparkle.zip"
CHECKSUM="$OUTPUT_DIRECTORY/Lima-Sparkle.sha256"

[[ -d "$APP_DIRECTORY" ]] || { print -u2 "Lima.app has not been packaged: $APP_DIRECTORY"; exit 1; }
[[ ! -f "$APP_DIRECTORY/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin" ]] || {
    print -u2 'Refusing to create a Sparkle archive containing the full Whisper model; package the model-free update app first.'
    exit 1
}
RAYPLACEMENT_MODEL_FREE_UPDATE=1 "$SCRIPT_DIRECTORY/verify_liamflow_app.sh" "$APP_DIRECTORY"
mkdir -p "$OUTPUT_DIRECTORY"
rm -f "$ARCHIVE" "$CHECKSUM"

TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/lima-sparkle-archive.XXXXXX")"
cleanup() {
    [[ "$TEMP_DIRECTORY" == "${TMPDIR%/}"/lima-sparkle-archive.* ]] && rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

ditto "$APP_DIRECTORY" "$TEMP_DIRECTORY/Lima.app"
(
    cd "$TEMP_DIRECTORY"
    ditto -c -k --sequesterRsrc --keepParent Lima.app "$ARCHIVE"
)
ARCHIVE_BYTES="$(/usr/bin/stat -f %z "$ARCHIVE")"
(( ARCHIVE_BYTES > 0 && ARCHIVE_BYTES <= LIMA_RELEASE_MAX_UPDATE_BYTES )) || {
    print -u2 "Refusing to publish a Sparkle archive larger than the configured $LIMA_RELEASE_MAX_UPDATE_BYTES-byte safety limit."
    exit 1
}
(
    cd "$OUTPUT_DIRECTORY"
    shasum -a 256 "${ARCHIVE:t}" > "${CHECKSUM:t}"
)
print "Created: $ARCHIVE"
