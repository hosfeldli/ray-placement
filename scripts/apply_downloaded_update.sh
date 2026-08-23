#!/bin/zsh
set -euo pipefail

if (( $# != 5 && $# != 6 )); then
    echo "Usage: apply_downloaded_update.sh <pid> <current-app> <source-root> <version> <result-file> [progress-file]"
    exit 2
fi

CURRENT_PID="$1"
CURRENT_APP="$2"
SOURCE_ROOT="$3"
VERSION="$4"
RESULT_FILE="$5"
# RayPlacement 1.7.x passes five arguments and closes before launching this
# helper. Keep that path working so an older installation can update into the
# new visible-progress flow. Version 1.8+ supplies the sixth progress file.
PROGRESS_FILE="${6:-$(dirname "$RESULT_FILE")/update-progress.txt}"
USER_HOME_DIRECTORY="${HOME:?The current user home folder is unavailable}"
USER_APPLICATIONS_DIRECTORY="$USER_HOME_DIRECTORY/Applications"
INSTALLED_APP="$USER_APPLICATIONS_DIRECTORY/RayPlacement.app"
BUILT_APP="$SOURCE_ROOT/build/RayPlacement.app"
EXTENSIONS_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Extensions"
BACKUP_APP="$USER_APPLICATIONS_DIRECTORY/.RayPlacement.previous-update.$$"

write_atomic_lines() {
    local destination="$1"
    shift
    local temporary="$destination.tmp.$$"
    mkdir -p "$(dirname "$destination")"
    printf '%s\n' "$@" > "$temporary"
    mv "$temporary" "$destination"
}

write_result() {
    write_atomic_lines "$RESULT_FILE" "$1" "$2"
}

write_progress() {
    write_atomic_lines "$PROGRESS_FILE" "$1" "$2" "$3"
}

fail_update() {
    local message="$1"
    echo "$message"
    write_result failure "$message"
    write_progress failure 0 "$message"
    exit 1
}

restore_previous_app() {
    if [[ -d "$BACKUP_APP" ]]; then
        rm -rf "$INSTALLED_APP"
        mv "$BACKUP_APP" "$INSTALLED_APP"
    fi
}

[[ -d "$CURRENT_APP/Contents/Resources/Qwen" ]] || fail_update "The installed Qwen model is missing. Reinstall RayPlacement from the full Desktop installer."
[[ -x "$SOURCE_ROOT/scripts/package_app.sh" ]] || fail_update "The verified update packager is missing."
[[ -x "$SOURCE_ROOT/scripts/setup_local_signing.sh" ]] || fail_update "The verified signing setup is missing."

write_progress working 0.34 "Reusing the verified local Qwen model — no model download needed…"
mkdir -p "$SOURCE_ROOT/Packaging/Vendor"
ditto "$CURRENT_APP/Contents/Resources/Qwen" "$SOURCE_ROOT/Packaging/Vendor/Qwen"

write_progress working 0.42 "Preparing this Mac's stable RayPlacement signing identity…"
"$SOURCE_ROOT/scripts/setup_local_signing.sh"

write_progress working 0.52 "Building RayPlacement $VERSION locally while the current app stays open…"
RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$SOURCE_ROOT/scripts/package_app.sh"
[[ -d "$BUILT_APP" ]] || fail_update "RayPlacement $VERSION finished building without a usable app bundle."
codesign --verify --deep --strict "$BUILT_APP" || fail_update "The newly built RayPlacement app did not pass signature verification."

write_progress ready 0.90 "Build verified. RayPlacement will close briefly, install, and reopen…"

for _ in {1..240}; do
    kill -0 "$CURRENT_PID" >/dev/null 2>&1 || break
    sleep 0.25
done
kill -0 "$CURRENT_PID" >/dev/null 2>&1 && fail_update "RayPlacement did not close in time, so the update was cancelled."

write_progress installing 0.96 "Installing the verified app and bundled extensions…"
mkdir -p "$USER_APPLICATIONS_DIRECTORY" "$EXTENSIONS_DIRECTORY"
if [[ -d "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$BACKUP_APP"
fi
if ! ditto "$BUILT_APP" "$INSTALLED_APP"; then
    restore_previous_app
    fail_update "The verified app could not be copied into your Applications folder. The previous version was restored."
fi
if ! codesign --verify --deep --strict "$INSTALLED_APP"; then
    restore_previous_app
    fail_update "The installed update did not pass verification. The previous version was restored."
fi

if [[ -d "$SOURCE_ROOT/Extensions" ]]; then
    for SOURCE_EXTENSION in "$SOURCE_ROOT/Extensions"/*; do
        [[ -d "$SOURCE_EXTENSION" && -f "$SOURCE_EXTENSION/manifest.json" ]] || continue
        EXTENSION_NAME="$(basename "$SOURCE_EXTENSION")"
        INSTALLED_EXTENSION="$EXTENSIONS_DIRECTORY/$EXTENSION_NAME"
        rm -rf "$INSTALLED_EXTENSION"
        if ! ditto "$SOURCE_EXTENSION" "$INSTALLED_EXTENSION"; then
            echo "Warning: could not refresh extension $EXTENSION_NAME" >&2
        fi
    done
fi

rm -rf "$BACKUP_APP"
write_result success "RayPlacement $VERSION was downloaded, verified, locally built, signed, and installed successfully."
write_progress success 1 "RayPlacement $VERSION is ready."
open "$INSTALLED_APP"
