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
READY_APP="$SOURCE_ROOT/Prebuilt/RayPlacement.app"
EXTENSIONS_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Extensions"
UPDATES_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Updates"
EXPECTED_SOURCE_ROOT="$UPDATES_DIRECTORY/pending/extracted/RayPlacementUpdate"
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

[[ -x "$SOURCE_ROOT/scripts/setup_local_signing.sh" ]] || fail_update "The verified signing setup is missing."
[[ -d "$READY_APP" ]] || fail_update "The verified prebuilt RayPlacement app is missing."

CURRENT_MODEL="$CURRENT_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
if [[ -f "$CURRENT_MODEL" ]]; then
    write_progress working 0.38 "Restoring this Mac's local dictation model…"
    mkdir -p "$READY_APP/Contents/Resources/Whisper/model"
    cp "$CURRENT_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin" \
        "$READY_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
else
    fail_update "The existing RayPlacement dictation model is unavailable, so the update was not installed."
fi

write_progress working 0.42 "Preparing this Mac's stable RayPlacement signing identity…"
"$SOURCE_ROOT/scripts/setup_local_signing.sh"

write_progress working 0.52 "Locally signing the verified RayPlacement $VERSION app…"
LOCAL_SIGNING_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Signing"
LOCAL_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIRECTORY/RayPlacementSigning.keychain-db"
LOCAL_SIGNING_PASSWORD="$LOCAL_SIGNING_DIRECTORY/keychain-password"
LOCAL_SIGNING_IDENTITY="RayPlacement Local Code Signing"
[[ -f "$LOCAL_SIGNING_KEYCHAIN" && -f "$LOCAL_SIGNING_PASSWORD" ]] || fail_update "The local RayPlacement signing identity is unavailable."
KEYCHAIN_PASSWORD="$(<"$LOCAL_SIGNING_PASSWORD")"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOCAL_SIGNING_KEYCHAIN"
LOCAL_SIGNING_HASH="$(security find-identity -v -p codesigning "$LOCAL_SIGNING_KEYCHAIN" | awk -v identity="$LOCAL_SIGNING_IDENTITY" 'index($0, "\\\"" identity "\\\"") { print $2; exit }')"
[[ -n "$LOCAL_SIGNING_HASH" ]] || fail_update "The local RayPlacement signing identity is not trusted for code signing."
ORIGINAL_USER_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}")
security list-keychains -d user -s "$LOCAL_SIGNING_KEYCHAIN" "${ORIGINAL_USER_KEYCHAINS[@]}"
if ! codesign --force --deep --sign "$LOCAL_SIGNING_HASH" "$READY_APP"; then
    security list-keychains -d user -s "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null
    fail_update "RayPlacement $VERSION could not be signed with this Mac's stable identity."
fi
security list-keychains -d user -s "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null
RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$SOURCE_ROOT/scripts/verify_app.sh" "$READY_APP" || fail_update "The locally signed RayPlacement $VERSION app did not pass verification."

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
write_result success "RayPlacement $VERSION was downloaded, verified, locally signed, and installed successfully."
write_progress success 1 "RayPlacement $VERSION is ready."
# A successful local build temporarily contains another full copy of Whisper.
# Remove only the updater-owned, exactly validated working directory after the
# signed app and extensions are safely installed. Failed builds are retained so
# their log and files remain available for troubleshooting.
if [[ "$SOURCE_ROOT" == "$EXPECTED_SOURCE_ROOT" ]]; then
    rm -rf "$UPDATES_DIRECTORY/pending"
fi
open "$INSTALLED_APP"
