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
INSTALLED_APP="$USER_APPLICATIONS_DIRECTORY/Lima.app"
READY_APP="$SOURCE_ROOT/Prebuilt/Lima.app"
EXTENSIONS_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Extensions"
UPDATES_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Updates"
EXPECTED_SOURCE_ROOT="$UPDATES_DIRECTORY/pending/extracted/LimaUpdate"
BACKUP_APP="$USER_APPLICATIONS_DIRECTORY/.Lima.previous-update.$$"

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

[[ -d "$READY_APP" ]] || fail_update "The verified prebuilt Lima app is missing."

CURRENT_MODEL="$CURRENT_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
if [[ -f "$CURRENT_MODEL" ]]; then
    write_progress working 0.38 "Restoring this Mac's local dictation model…"
    mkdir -p "$READY_APP/Contents/Resources/Whisper/model"
    cp "$CURRENT_MODEL" \
        "$READY_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
else
    write_progress working 0.38 "Downloading the verified local dictation model for this Mac…"
    if ! "$SOURCE_ROOT/scripts/assemble_whisper_model.sh"; then
        fail_update "The local dictation model could not be restored or downloaded, so the update was not installed."
    fi
    DOWNLOADED_MODEL="$SOURCE_ROOT/Packaging/Vendor/Whisper/model/ggml-small.en-tdrz.bin"
    [[ -f "$DOWNLOADED_MODEL" ]] || fail_update "The downloaded local dictation model is unavailable."
    mkdir -p "$READY_APP/Contents/Resources/Whisper/model"
    cp "$DOWNLOADED_MODEL" "$READY_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
fi

write_progress working 0.52 "Verifying and preparing Lima $VERSION for this Mac…"
codesign --force --deep --sign - "$READY_APP" || fail_update "Lima $VERSION could not be prepared for installation."
"$SOURCE_ROOT/scripts/verify_liamflow_app.sh" "$READY_APP" || fail_update "The verified Lima $VERSION app did not pass inspection."

write_progress ready 0.90 "Lima is verified. It will close briefly, install, and reopen…"

for _ in {1..240}; do
    kill -0 "$CURRENT_PID" >/dev/null 2>&1 || break
    sleep 0.25
done
kill -0 "$CURRENT_PID" >/dev/null 2>&1 && fail_update "Lima did not close in time, so the update was cancelled."

write_progress installing 0.96 "Installing the verified app and bundled extensions…"
mkdir -p "$USER_APPLICATIONS_DIRECTORY" "$EXTENSIONS_DIRECTORY"
if [[ -d "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$BACKUP_APP"
fi
if ! ditto "$READY_APP" "$INSTALLED_APP"; then
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
write_result success "Lima $VERSION was downloaded, verified, and installed successfully."
write_progress success 1 "Lima $VERSION is ready."
# A successful local build temporarily contains another full copy of Whisper.
# Remove only the updater-owned, exactly validated working directory after the
# signed app and extensions are safely installed. Failed builds are retained so
# their log and files remain available for troubleshooting.
if [[ "$SOURCE_ROOT" == "$EXPECTED_SOURCE_ROOT" ]]; then
    rm -rf "$UPDATES_DIRECTORY/pending"
fi
open "$INSTALLED_APP"
