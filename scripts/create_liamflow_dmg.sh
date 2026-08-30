#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_DIRECTORY="${1:-$PROJECT_DIRECTORY/dist}"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/lima-dmg.XXXXXX")"
APP_DIRECTORY="$PROJECT_DIRECTORY/build/Lima.app"

cleanup() {
    [[ "$TEMP_DIRECTORY" == "${TMPDIR%/}"/lima-dmg.* ]] && rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

[[ -d "$APP_DIRECTORY" ]] || { echo "Lima.app has not been packaged."; exit 1; }
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
STAGE="$TEMP_DIRECTORY/Lima"
mkdir -p "$STAGE"
ditto "$APP_DIRECTORY" "$STAGE/Lima.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUTPUT_DIRECTORY/Lima.dmg"
hdiutil create -volname "Lima" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT_DIRECTORY/Lima.dmg" >/dev/null
shasum -a 256 "$OUTPUT_DIRECTORY/Lima.dmg" > "$OUTPUT_DIRECTORY/Lima.dmg.sha256"
echo "Created: $OUTPUT_DIRECTORY/Lima.dmg"
