#!/bin/zsh
set -euo pipefail

if (( $# != 5 )); then
    echo "Usage: apply_downloaded_update.sh <pid> <current-app> <source-root> <version> <result-file>"
    exit 2
fi

CURRENT_PID="$1"
CURRENT_APP="$2"
SOURCE_ROOT="$3"
VERSION="$4"
RESULT_FILE="$5"
USER_HOME_DIRECTORY="${HOME:?The current user home folder is unavailable}"
INSTALLED_APP="$USER_HOME_DIRECTORY/Applications/RayPlacement.app"

write_result() {
    local status="$1"
    local message="$2"
    local temporary_result="$RESULT_FILE.tmp.$$"
    mkdir -p "$(dirname "$RESULT_FILE")"
    printf '%s\n%s\n' "$status" "$message" > "$temporary_result"
    mv "$temporary_result" "$RESULT_FILE"
}

fail_update() {
    local message="$1"
    echo "$message"
    write_result failure "$message"
    [[ -d "$INSTALLED_APP" ]] && open "$INSTALLED_APP" >/dev/null 2>&1 || true
    exit 1
}

for _ in {1..120}; do
    kill -0 "$CURRENT_PID" >/dev/null 2>&1 || break
    sleep 0.25
done
kill -0 "$CURRENT_PID" >/dev/null 2>&1 && fail_update "RayPlacement did not close in time, so the update was cancelled."

[[ -d "$CURRENT_APP/Contents/Resources/Qwen" ]] || fail_update "The installed Qwen model is missing. Reinstall RayPlacement from the full Desktop installer."
[[ -x "$SOURCE_ROOT/Install RayPlacement.command" ]] || fail_update "The verified update installer is missing."

mkdir -p "$SOURCE_ROOT/Packaging/Vendor"
ditto "$CURRENT_APP/Contents/Resources/Qwen" "$SOURCE_ROOT/Packaging/Vendor/Qwen"

echo "Building and signing RayPlacement $VERSION locally…"
if ! RAYPLACEMENT_APPROVE_LOCAL_SIGNING=1 \
    RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 \
    RAYPLACEMENT_SKIP_LAUNCH=1 \
    "$SOURCE_ROOT/Install RayPlacement.command"; then
    fail_update "RayPlacement $VERSION could not be built or installed. See ~/Library/Application Support/RayPlacement/Updates/update.log for details."
fi

write_result success "RayPlacement $VERSION was verified, locally signed, and installed successfully."
open "$INSTALLED_APP"
