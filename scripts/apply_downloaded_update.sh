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
# Update the exact running copy. Never silently create a second installation.
INSTALLED_APP="${CURRENT_APP:A}"
READY_APP="$SOURCE_ROOT/Prebuilt/Lima.app"
EXTENSIONS_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Extensions"
UPDATES_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Updates"
EXPECTED_SOURCE_ROOT="$UPDATES_DIRECTORY/pending/extracted/LimaUpdate"
TRANSACTION=""

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
    trap - EXIT
    echo "$message"
    write_result failure "$message"
    write_progress failure 0 "$message"
    exit 1
}

unexpected_exit() {
    local result=$?
    if (( result != 0 )); then
        write_result failure 'The update stopped unexpectedly. The installation log contains the failed step; the previous app is preserved.'
        write_progress failure 0 'Update stopped. See update.log for details.'
    fi
}
trap unexpected_exit EXIT

[[ -d "$READY_APP" ]] || fail_update "The verified prebuilt Lima app is missing."
[[ "$CURRENT_PID" == <-> && "$CURRENT_PID" -gt 1 ]] || fail_update "The running app process is invalid."
[[ "$INSTALLED_APP" == /*.app && -d "$INSTALLED_APP" ]] || fail_update "The running app location is invalid."
[[ "$INSTALLED_APP" != /Volumes/* && "$INSTALLED_APP" != *'/AppTranslocation/'* ]] || fail_update "Drag Lima from the disk image into Applications, open that copy, then check for updates."
[[ -w "${INSTALLED_APP:h}" ]] || fail_update "Lima cannot replace $INSTALLED_APP. Install the new DMG with Finder and approve access to Applications. The current app is unchanged."
echo "Update target: $INSTALLED_APP"
echo "Requested version: $VERSION"

CURRENT_MODEL="$CURRENT_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
MODEL_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Whisper/model"
CACHED_MODEL="$MODEL_DIRECTORY/ggml-small.en-tdrz.bin"
MODEL_HASH="ceac3ec06d1d98ef71aec665283564631055fd6129b79d8e1be4f9cc33cc54b4"
model_valid() { [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$MODEL_HASH" ]]; }
# The large model lives outside the app after updates. Keeping the downloaded
# bundle intact preserves its signature and requires no per-device signing key.
mkdir -p "$MODEL_DIRECTORY"
if model_valid "$CACHED_MODEL"; then
    write_progress working 0.38 "Verified the existing local dictation model."
elif model_valid "$CURRENT_MODEL"; then
    write_progress working 0.38 "Preserving this Mac's verified dictation model…"
    cp "$CURRENT_MODEL" "$CACHED_MODEL.pending.$$"
    mv "$CACHED_MODEL.pending.$$" "$CACHED_MODEL"
else
    write_progress working 0.38 "Downloading the verified local dictation model for this Mac…"
    if ! "$SOURCE_ROOT/scripts/assemble_whisper_model.sh"; then
        fail_update "The local dictation model could not be restored or downloaded, so the update was not installed."
    fi
    DOWNLOADED_MODEL="$SOURCE_ROOT/Packaging/Vendor/Whisper/model/ggml-small.en-tdrz.bin"
    [[ -f "$DOWNLOADED_MODEL" ]] || fail_update "The downloaded local dictation model is unavailable."
    cp "$DOWNLOADED_MODEL" "$CACHED_MODEL.pending.$$"
    mv "$CACHED_MODEL.pending.$$" "$CACHED_MODEL"
fi

write_progress working 0.52 "Verifying and preparing Lima $VERSION for this Mac…"
RAYPLACEMENT_MODEL_FREE_UPDATE=1 "$SOURCE_ROOT/scripts/verify_liamflow_app.sh" "$READY_APP" || fail_update "The verified Lima $VERSION app did not pass inspection."
# Existing locally signed installations can keep that exact identity. Never
# create trust roots or require a developer's private key on a fresh Mac.
LOCAL_KEYCHAIN="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Signing/RayPlacementSigning.keychain-db"
if [[ -f "$LOCAL_KEYCHAIN" ]]; then
    LOCAL_HASH="$(security find-identity -v -p codesigning "$LOCAL_KEYCHAIN" | awk '/"RayPlacement Local Code Signing"/ {print $2; exit}')"
    if [[ -n "$LOCAL_HASH" ]] && codesign --verify -R "anchor = H\"$LOCAL_HASH\"" "$CURRENT_APP" >/dev/null 2>&1; then
        "$SOURCE_ROOT/scripts/sign_lima_app.sh" "$READY_APP" || fail_update 'The existing local signing identity could not be reused. The current app is unchanged.'
    fi
fi
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$READY_APP/Contents/Info.plist")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$READY_APP/Contents/Info.plist")" == "$VERSION" ]] || fail_update "The downloaded app is not version $VERSION."
TRANSACTION="$(mktemp -d "${INSTALLED_APP:h}/.lima-install.XXXXXX")" || fail_update "The app folder cannot be prepared for installation."

write_progress ready 0.90 "Lima is verified. It will close briefly, install, and reopen…"

for _ in {1..240}; do
    kill -0 "$CURRENT_PID" >/dev/null 2>&1 || break
    sleep 0.25
done
kill -0 "$CURRENT_PID" >/dev/null 2>&1 && fail_update "Lima did not close in time, so the update was cancelled."

write_progress installing 0.96 "Replacing $INSTALLED_APP with Lima $VERSION…"
if ! /bin/zsh "$SOURCE_ROOT/scripts/replace_lima_bundle.sh" "$READY_APP" "$INSTALLED_APP" "$VERSION" "$TRANSACTION"; then
    /usr/bin/open -n "$INSTALLED_APP" || true
    fail_update "The app replacement failed. The previous copy was preserved. See update.log for details."
fi
mkdir -p "$EXTENSIONS_DIRECTORY"

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

# The relaunched app must match this receipt before it reports success.
write_atomic_lines "$RESULT_FILE" success "Lima $VERSION ($BUILD) installed at $INSTALLED_APP." "$VERSION" "$BUILD" "$INSTALLED_APP"
write_progress success 1 "Lima $VERSION is installed. Reopening the updated copy…"
if ! /usr/bin/open -n "$INSTALLED_APP"; then
    fail_update "Lima $VERSION was installed at $INSTALLED_APP but could not reopen. Open it in Finder. The previous copy is retained at $TRANSACTION/Previous.app."
fi
echo "Previous app retained for recovery: $TRANSACTION/Previous.app"
trap - EXIT
# A successful local build temporarily contains another full copy of Whisper.
# Remove only the updater-owned, exactly validated working directory after the
# signed app and extensions are safely installed. Failed builds are retained so
# their log and files remain available for troubleshooting.
if [[ "$SOURCE_ROOT" == "$EXPECTED_SOURCE_ROOT" ]]; then
    rm -rf "$UPDATES_DIRECTORY/pending"
fi
