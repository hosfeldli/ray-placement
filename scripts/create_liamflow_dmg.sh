#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_DIRECTORY="${1:-$PROJECT_DIRECTORY/dist}"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/liamflow-dmg.XXXXXX")"
APP_DIRECTORY="$PROJECT_DIRECTORY/build/LiamFlow.app"

cleanup() {
    [[ "$TEMP_DIRECTORY" == "${TMPDIR%/}"/liamflow-dmg.* ]] && rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

[[ -d "$APP_DIRECTORY" ]] || { echo "LiamFlow.app has not been packaged."; exit 1; }
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
STAGE="$TEMP_DIRECTORY/LiamFlow"
mkdir -p "$STAGE"
ditto "$APP_DIRECTORY" "$STAGE/LiamFlow.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUTPUT_DIRECTORY/LiamFlow.dmg"
hdiutil create -volname "LiamFlow" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT_DIRECTORY/LiamFlow.dmg" >/dev/null
shasum -a 256 "$OUTPUT_DIRECTORY/LiamFlow.dmg" > "$OUTPUT_DIRECTORY/LiamFlow.dmg.sha256"
echo "Created: $OUTPUT_DIRECTORY/LiamFlow.dmg"
