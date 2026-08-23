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

STAGED_SOURCE="$TEMP_DIRECTORY/RayPlacementUpdate"
mkdir -p "$STAGED_SOURCE" "$OUTPUT_DIRECTORY"
rsync -a \
    --exclude .git/ \
    --exclude .github/ \
    --exclude .build/ \
    --exclude build/ \
    --exclude dist/ \
    --exclude Downloads/ \
    --exclude Packaging/Vendor/ \
    --exclude .DS_Store \
    "$PROJECT_DIRECTORY/" "$STAGED_SOURCE/"

ARCHIVE="$OUTPUT_DIRECTORY/RayPlacement-Update.zip"
rm -f "$ARCHIVE" "$OUTPUT_DIRECTORY/RayPlacement-Update.sha256"
(
    cd "$TEMP_DIRECTORY"
    ditto -c -k --sequesterRsrc --keepParent RayPlacementUpdate "$ARCHIVE"
)
(
    cd "$OUTPUT_DIRECTORY"
    shasum -a 256 "$(basename "$ARCHIVE")" > RayPlacement-Update.sha256
)
echo "Created: $ARCHIVE"
