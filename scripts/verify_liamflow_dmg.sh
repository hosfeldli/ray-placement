#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
DMG="${1:?Usage: verify_liamflow_dmg.sh <Lima.dmg>}"
MOUNT_POINT="$(mktemp -d "${TMPDIR%/}/lima-dmg-mount.XXXXXX")"
DEVICE=""
cleanup() {
    if [[ -n "$DEVICE" ]]; then hdiutil detach "$DEVICE" >/dev/null 2>&1 || true; fi
    rm -rf "$MOUNT_POINT"
}
trap cleanup EXIT
[[ -f "$DMG" && ! -L "$DMG" ]] || { echo 'Verification failed: DMG is missing or symbolic' >&2; exit 1; }
hdiutil verify "$DMG" >/dev/null
DEVICE="$(hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" "$DMG" | awk 'END {print $1}')"
[[ -d "$MOUNT_POINT/Lima.app" && ! -L "$MOUNT_POINT/Lima.app" ]] || { echo 'Verification failed: DMG does not contain Lima.app' >&2; exit 1; }
RAYPLACEMENT_MODEL_FREE_UPDATE=0 "$SCRIPT_DIRECTORY/verify_liamflow_app.sh" "$MOUNT_POINT/Lima.app"
echo "Verified Lima.dmg"
