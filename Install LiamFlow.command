#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIRECTORY/LiamFlow.app"
SOURCE_EXTENSIONS="$SCRIPT_DIRECTORY/Extensions"
CURRENT_USER="$(id -un)"
USER_HOME_DIRECTORY="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory | awk '{print $2}')"
[[ -n "$USER_HOME_DIRECTORY" && "$USER_HOME_DIRECTORY" == /Users/* ]] || { echo "Could not safely locate your user folder."; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { echo "LiamFlow currently requires an Apple-silicon Mac."; exit 1; }
[[ -d "$SOURCE_APP" ]] || { echo "LiamFlow.app is missing from this disk image."; exit 1; }

APPLICATIONS_DIRECTORY="$USER_HOME_DIRECTORY/Applications"
INSTALLED_APP="$APPLICATIONS_DIRECTORY/LiamFlow.app"
EXTENSIONS_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Extensions"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/liamflow-install.XXXXXX")"
WORKING_APP="$TEMP_DIRECTORY/LiamFlow.app"
MODEL="$WORKING_APP/Contents/Resources/Whisper/model/ggml-small.en-tdrz.bin"
MODEL_URL="https://huggingface.co/akashmjn/tinydiarize-whisper.cpp/resolve/d44ba793fc67e509623a88a409723311fa677744/ggml-small.en-tdrz.bin?download=true"
MODEL_SHA256="ceac3ec06d1d98ef71aec665283564631055fd6129b79d8e1be4f9cc33cc54b4"
STAMP="$(date +%Y%m%d-%H%M%S)"

cleanup() { [[ "$TEMP_DIRECTORY" == "${TMPDIR%/}"/liamflow-install.* ]] && rm -rf "$TEMP_DIRECTORY"; }
trap cleanup EXIT INT TERM

echo "LiamFlow installer"
echo "A local dictation model (about 465 MB) will download once and stay on this Mac."
if [[ -t 0 ]]; then
    read "REPLY?Install LiamFlow now? [y/N] "
    [[ "$REPLY" == [yY] ]] || { echo "Installation cancelled."; exit 0; }
fi

ditto "$SOURCE_APP" "$WORKING_APP"
mkdir -p "${MODEL:h}"
echo "Downloading and verifying the local dictation model…"
curl --fail --location --retry 3 --retry-all-errors --progress-bar "$MODEL_URL" --output "$MODEL"
[[ "$(shasum -a 256 "$MODEL" | awk '{print $1}')" == "$MODEL_SHA256" ]] || { echo "The dictation model did not pass verification."; exit 1; }
codesign --force --deep --sign - "$WORKING_APP"
codesign --verify --deep --strict "$WORKING_APP"

mkdir -p "$APPLICATIONS_DIRECTORY" "$EXTENSIONS_DIRECTORY" "$USER_HOME_DIRECTORY/.Trash"
pkill -x LiamFlow >/dev/null 2>&1 || true
if [[ -d "$INSTALLED_APP" ]]; then
    mv "$INSTALLED_APP" "$USER_HOME_DIRECTORY/.Trash/LiamFlow-Previous-$STAMP.app"
fi
ditto "$WORKING_APP" "$INSTALLED_APP"
if [[ -d "$SOURCE_EXTENSIONS" ]]; then
    for extension in "$SOURCE_EXTENSIONS"/*; do
        [[ -d "$extension" && -f "$extension/manifest.json" ]] || continue
        destination="$EXTENSIONS_DIRECTORY/${extension:t}"
        rm -rf "$destination"
        ditto "$extension" "$destination"
    done
fi
codesign --verify --deep --strict "$INSTALLED_APP"
open "$INSTALLED_APP"
echo "LiamFlow is installed in $INSTALLED_APP"
