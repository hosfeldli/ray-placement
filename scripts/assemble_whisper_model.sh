#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
WHISPER_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Whisper"
MODEL_DIRECTORY="$WHISPER_DIRECTORY/model"
MODEL="$MODEL_DIRECTORY/ggml-small.en-tdrz.bin"
EXPECTED_MODEL_SHA256="ceac3ec06d1d98ef71aec665283564631055fd6129b79d8e1be4f9cc33cc54b4"
DEFAULT_MODEL_URL="https://huggingface.co/akashmjn/tinydiarize-whisper.cpp/resolve/d44ba793fc67e509623a88a409723311fa677744/ggml-small.en-tdrz.bin?download=true"
MODEL_URL="${RAYPLACEMENT_WHISPER_MODEL_URL:-$DEFAULT_MODEL_URL}"
PREBUILT_MODEL="$PROJECT_DIRECTORY/build/Lima.app/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
INSTALLED_MODEL="${HOME:?The current user home folder is unavailable}/Applications/Lima.app/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
TEMP_MODEL="$MODEL_DIRECTORY/.ggml-small.en-tdrz.bin.downloading.$$"

cleanup() {
    rm -f "$TEMP_MODEL"
}
trap cleanup EXIT INT TERM

model_is_valid() {
    local candidate="$1"
    [[ -f "$candidate" ]] || return 1
    [[ "$(shasum -a 256 "$candidate" | awk '{print $1}')" == "$EXPECTED_MODEL_SHA256" ]]
}

mkdir -p "$MODEL_DIRECTORY"
if model_is_valid "$MODEL"; then
    exit 0
fi

for candidate in "$PREBUILT_MODEL" "$INSTALLED_MODEL"; do
    if model_is_valid "$candidate"; then
        echo "Restoring Local Whisper from a verified RayPlacement copy…"
        cp "$candidate" "$TEMP_MODEL"
        mv -f "$TEMP_MODEL" "$MODEL"
        exit 0
    fi
done

echo "Downloading the pinned Local Whisper small.en TinyDiarize model (about 465 MB)…"
if ! curl --fail --location --retry 3 --retry-all-errors --progress-bar "$MODEL_URL" --output "$TEMP_MODEL"; then
    echo "Local Whisper could not be downloaded. Check the network connection and run the installer again."
    exit 1
fi
if ! model_is_valid "$TEMP_MODEL"; then
    ACTUAL_SHA256="$(shasum -a 256 "$TEMP_MODEL" | awk '{print $1}')"
    echo "The downloaded Local Whisper model did not match its pinned SHA-256."
    echo "Expected: $EXPECTED_MODEL_SHA256"
    echo "Received: $ACTUAL_SHA256"
    exit 1
fi
mv -f "$TEMP_MODEL" "$MODEL"
echo "Downloaded and verified Local Whisper small.en TinyDiarize."
