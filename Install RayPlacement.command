#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$SCRIPT_DIRECTORY/build/RayPlacement.app"
SOURCE_EXTENSIONS_DIRECTORY="$SCRIPT_DIRECTORY/Extensions"
PACKAGE_MANIFEST="$SCRIPT_DIRECTORY/Package.swift"
SIGNING_SETUP="$SCRIPT_DIRECTORY/scripts/setup_local_signing.sh"
PACKAGE_SCRIPT="$SCRIPT_DIRECTORY/scripts/package_app.sh"
WHISPER_ASSEMBLER="$SCRIPT_DIRECTORY/scripts/assemble_whisper_model.sh"
CURRENT_USER="$(id -un)"
USER_HOME_DIRECTORY="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory | awk '{print $2}')"

if [[ -z "$USER_HOME_DIRECTORY" || "$USER_HOME_DIRECTORY" != /Users/* ]]; then
    echo "Could not safely locate your user folder."
    exit 1
fi

USER_APPLICATIONS_DIRECTORY="$USER_HOME_DIRECTORY/Applications"
INSTALLED_APP="$USER_APPLICATIONS_DIRECTORY/RayPlacement.app"
EXTENSIONS_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Extensions"
LEGACY_WRITING_MANIFEST="$EXTENSIONS_DIRECTORY/manifest.json"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "This RayPlacement build currently requires an Apple-silicon Mac."
    exit 1
fi

if [[ -f "$PACKAGE_MANIFEST" && -x "$SIGNING_SETUP" && -x "$PACKAGE_SCRIPT" && -x "$WHISPER_ASSEMBLER" ]]; then
    if ! xcrun --find swiftc >/dev/null 2>&1; then
        echo "Apple Command Line Tools are required for the first local setup."
        echo "Run: xcode-select --install"
        echo "Then open this installer again."
        exit 1
    fi
    if ! swift --version | grep -Eq 'Swift version ([6-9]|[1-9][0-9])\.'; then
        echo "RayPlacement requires Swift 6 from Xcode 16 or newer Command Line Tools."
        echo "Update Apple Command Line Tools, then open this installer again."
        exit 1
    fi

    "$WHISPER_ASSEMBLER"
    WHISPER_MODEL="$SCRIPT_DIRECTORY/Packaging/Vendor/Whisper/model/ggml-small.en-tdrz.bin"
    WHISPER_RUNTIME="$SCRIPT_DIRECTORY/Packaging/WhisperRuntime/whisper-cli"
    if [[ ! -f "$WHISPER_MODEL" || "$(stat -f '%z' "$WHISPER_MODEL" 2>/dev/null || echo 0)" -lt 400000000 \
        || ! -x "$WHISPER_RUNTIME" ]]; then
        echo "The local Whisper meeting model or runtime is incomplete."
        echo "Check the network connection, then open this installer again."
        exit 1
    fi

    if [[ "${RAYPLACEMENT_APPROVE_LOCAL_SIGNING:-0}" != "1" ]]; then
        echo
        echo "RayPlacement will create a private signing key used only on this Mac."
        echo "The private key stays in:"
        echo "  $USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Signing"
        echo "Only its public certificate is added to your login keychain, with a"
        echo "code-signing-only trust policy. This gives every locally rebuilt copy"
        echo "the same identity so macOS Accessibility approval survives updates."
        echo "Anyone who obtains the private key could sign another app as this local"
        echo "identity. The key is never uploaded or copied to another computer."
        echo
        if [[ -t 0 ]]; then
            read "REPLY?Continue with local signing and installation? [y/N] "
            [[ "$REPLY" == [yY] ]] || { echo "Installation cancelled."; exit 1; }
        else
            echo "Run this installer interactively, or set RAYPLACEMENT_APPROVE_LOCAL_SIGNING=1 after reviewing the notice."
            exit 1
        fi
    fi

    echo
    echo "Preparing a stable build for this Mac…"
    "$SIGNING_SETUP"
    RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$PACKAGE_SCRIPT"
fi

if [[ ! -d "$SOURCE_APP" || ! -d "$SOURCE_EXTENSIONS_DIRECTORY" ]]; then
    echo "The RayPlacement app or bundled extensions are missing from this folder."
    echo "Open the complete project folder and run this installer again."
    exit 1
fi

codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$USER_APPLICATIONS_DIRECTORY" "$EXTENSIONS_DIRECTORY"
pkill -x RayPlacement >/dev/null 2>&1 || true

if [[ -d "$INSTALLED_APP" ]]; then
    rm -rf "$INSTALLED_APP"
fi
if [[ -f "$LEGACY_WRITING_MANIFEST" ]] && grep -q '"id"[[:space:]]*:[[:space:]]*"local.writing-tools"' "$LEGACY_WRITING_MANIFEST"; then
    mv "$LEGACY_WRITING_MANIFEST" "$EXTENSIONS_DIRECTORY/writing-tools-legacy-manifest.backup"
fi

ditto "$SOURCE_APP" "$INSTALLED_APP"
for SOURCE_EXTENSION in "$SOURCE_EXTENSIONS_DIRECTORY"/*; do
    [[ -d "$SOURCE_EXTENSION" && -f "$SOURCE_EXTENSION/manifest.json" ]] || continue
    EXTENSION_NAME="$(basename "$SOURCE_EXTENSION")"
    INSTALLED_EXTENSION="$EXTENSIONS_DIRECTORY/$EXTENSION_NAME"
    if [[ -d "$INSTALLED_EXTENSION" ]]; then
        rm -rf "$INSTALLED_EXTENSION"
    fi
    ditto "$SOURCE_EXTENSION" "$INSTALLED_EXTENSION"
done
codesign --verify --deep --strict "$INSTALLED_APP"
if [[ "${RAYPLACEMENT_SKIP_LAUNCH:-0}" != "1" ]]; then
    open "$INSTALLED_APP"
fi

echo
echo "RayPlacement, Notes, Writing Tools, Endpoint Tester, Password Generator, Emoji Picker, Focused File Launcher, Productivity Tools, and Document Formatter are installed."
echo "App: $INSTALLED_APP"
echo "Plain-text paste: Control-Option-V"
echo "Writing check: Control-Option-G"
echo "Emoji picker: tap Command twice"
echo "The Emoji Picker uses the full Unicode 17.0 keyboard set in a searchable grid."
echo "Configure any extension shortcut in Settings → Extensions."
echo "Productivity Tools: offline timezone conversion and confirmed single/all-app force quit (RayPlacement stays open)."
echo "Writing checks use bundled Python spelling and Harper grammar rules; dictation is the only AI-powered feature."
echo "Choose Automatic, Metal, or CPU compute for Local Whisper in Settings → Performance."
echo "Monitor local dictation, grammar, and extension work in Settings → Usage."
echo "Notes use inline formatted Markdown and semi-live Local Whisper meeting dictation with pause and speaker-turn formatting."
echo "The compact top activity shelf shows supported Apple Music and Spotify controls while a track is playing."
echo "Document Formatter opens in a focused resizable workspace for EDI, JSON, and XML."
echo "Developer Terminal is a real PTY with ANSI, sequential shell state, and Control/Option-Meta input."
echo "Endpoint Tester imports Postman collections/environments and includes variables, inherited auth, runners, cURL, and response tabs."
echo "Extension schema v2 supports conditional, sectioned, file, directory, date, slider, key/value, and input/output forms."
echo "Uninstaller: $SCRIPT_DIRECTORY/Uninstall RayPlacement.command"
echo "Check selected-text access in Settings → General → Accessibility."
echo
echo "You can close this window."
