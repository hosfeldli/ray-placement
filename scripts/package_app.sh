#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
# An interrupted SwiftPM process can leave the default cache locked. The
# installer may supply an isolated, disposable scratch directory to complete a
# clean rebuild without competing with that stale process.
SCRATCH_DIRECTORY="${RAYPLACEMENT_SCRATCH_DIRECTORY:-$PROJECT_DIRECTORY/.build}"
# Supply a known-good compiler cache when a cold Swift toolchain cache is slow
# or interrupted; otherwise keep all build artifacts inside the scratch path.
MODULE_CACHE_DIRECTORY="${RAYPLACEMENT_MODULE_CACHE_DIRECTORY:-$SCRATCH_DIRECTORY/module-cache}"
APP_DIRECTORY="$PROJECT_DIRECTORY/build/Lima.app"
CONTENTS_DIRECTORY="$APP_DIRECTORY/Contents"
ICON_MASTER="$PROJECT_DIRECTORY/Packaging/AppIcon-master.png"
ICON_FILE="$PROJECT_DIRECTORY/Packaging/RayPlacement.icns"
WHISPER_ASSEMBLER="$PROJECT_DIRECTORY/scripts/assemble_whisper_model.sh"
WHISPER_RUNTIME="$PROJECT_DIRECTORY/Packaging/WhisperRuntime"
WHISPER_MODEL="$PROJECT_DIRECTORY/Packaging/Vendor/Whisper/model/ggml-small.en-tdrz.bin"
MODEL_FREE_UPDATE_BUILD="${RAYPLACEMENT_MODEL_FREE_UPDATE:-0}"
HARPER_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Harper"
PYTHON_GRAMMAR_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/PythonGrammar"
BUNDLED_EXTENSIONS_DIRECTORY="$PROJECT_DIRECTORY/Extensions"
USER_HOME_DIRECTORY="${HOME:?The current user home folder is unavailable}"
LOCAL_SIGNING_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Signing"
LOCAL_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIRECTORY/RayPlacementSigning.keychain-db"
LOCAL_SIGNING_PASSWORD="$LOCAL_SIGNING_DIRECTORY/keychain-password"
LOCAL_SIGNING_IDENTITY="RayPlacement Local Code Signing"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIRECTORY"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIRECTORY"

mkdir -p "$MODULE_CACHE_DIRECTORY"
if [[ "$MODEL_FREE_UPDATE_BUILD" != "1" ]]; then
    "$WHISPER_ASSEMBLER"
fi
swift build --package-path "$PROJECT_DIRECTORY" --configuration release --disable-sandbox --scratch-path "$SCRATCH_DIRECTORY"
BIN_DIRECTORY="$(swift build --package-path "$PROJECT_DIRECTORY" --configuration release --disable-sandbox --scratch-path "$SCRATCH_DIRECTORY" --show-bin-path)"

if [[ -d "$APP_DIRECTORY" ]]; then
    rm -rf "$APP_DIRECTORY"
fi
mkdir -p "$CONTENTS_DIRECTORY/MacOS" "$CONTENTS_DIRECTORY/Resources"

cp "$BIN_DIRECTORY/RayPlacement" "$CONTENTS_DIRECTORY/MacOS/Lima"
cp "$PROJECT_DIRECTORY/Packaging/Info.plist" "$CONTENTS_DIRECTORY/Info.plist"

# Keep the uninstaller inside the bundle so the packaged app is self-contained
# and the release verifier checks the same artifact users receive.
cp "$PROJECT_DIRECTORY/Uninstall Lima.command" \
    "$CONTENTS_DIRECTORY/Resources/Uninstall Lima.command"
chmod 755 "$CONTENTS_DIRECTORY/Resources/Uninstall Lima.command"

if [[ ! -x "$WHISPER_RUNTIME/whisper-cli" ]]; then
    echo "The bundled Local Whisper runtime is incomplete."
    exit 1
fi
if [[ "$MODEL_FREE_UPDATE_BUILD" != "1" && ! -f "$WHISPER_MODEL" ]]; then
    echo "The bundled Local Whisper model is incomplete. Run scripts/assemble_whisper_model.sh first."
    exit 1
fi
mkdir -p "$CONTENTS_DIRECTORY/Resources/Whisper/runtime" "$CONTENTS_DIRECTORY/Resources/Whisper/model"
cp "$WHISPER_RUNTIME/whisper-cli" "$CONTENTS_DIRECTORY/Resources/Whisper/runtime/whisper-cli"
cp "$WHISPER_RUNTIME/LICENSE" "$CONTENTS_DIRECTORY/Resources/Whisper/LICENSE"
cp "$WHISPER_RUNTIME/REVISION" "$CONTENTS_DIRECTORY/Resources/Whisper/REVISION"
cp "$WHISPER_RUNTIME/MODEL_SOURCE" "$CONTENTS_DIRECTORY/Resources/Whisper/MODEL_SOURCE"
if [[ "$MODEL_FREE_UPDATE_BUILD" != "1" ]]; then
    cp "$WHISPER_MODEL" "$CONTENTS_DIRECTORY/Resources/Whisper/model/ggml-small.en-tdrz.bin"
fi
chmod 755 "$CONTENTS_DIRECTORY/Resources/Whisper/runtime/whisper-cli"

MISSING_WRITING_RESOURCES=()
[[ -f "$HARPER_DIRECTORY/harper-cli" ]] || MISSING_WRITING_RESOURCES+=("Harper/harper-cli")
[[ -f "$PYTHON_GRAMMAR_DIRECTORY/grammar_check.py" ]] || MISSING_WRITING_RESOURCES+=("PythonGrammar/grammar_check.py")
[[ -d "$PYTHON_GRAMMAR_DIRECTORY/site-packages/spellchecker" ]] || MISSING_WRITING_RESOURCES+=("PythonGrammar/site-packages/spellchecker")
if (( ${#MISSING_WRITING_RESOURCES[@]} > 0 )); then
    echo "The bundled rule-based writing resources are incomplete: ${(j:, :)MISSING_WRITING_RESOURCES}"
    exit 1
fi
mkdir -p "$CONTENTS_DIRECTORY/Resources/Tools/PythonGrammar"
cp "$HARPER_DIRECTORY/harper-cli" "$CONTENTS_DIRECTORY/Resources/Tools/harper-cli"
ditto "$PYTHON_GRAMMAR_DIRECTORY" "$CONTENTS_DIRECTORY/Resources/Tools/PythonGrammar"
chmod 755 "$CONTENTS_DIRECTORY/Resources/Tools/harper-cli" "$CONTENTS_DIRECTORY/Resources/Tools/PythonGrammar/grammar_check.py"

if [[ ! -f "$ICON_MASTER" ]]; then
    # Keep a deterministic fallback for source-only checkouts. A committed or
    # generated master is intentional artwork and must never be overwritten.
    swift "$PROJECT_DIRECTORY/scripts/make_icon.swift" "$ICON_MASTER"
fi
if [[ ! -f "$ICON_FILE" || "$ICON_MASTER" -nt "$ICON_FILE" || "${RAYPLACEMENT_REBUILD_ICON:-0}" == "1" ]]; then
    ICONSET_DIRECTORY="$PROJECT_DIRECTORY/Packaging/RayPlacement.iconset"
    if [[ -d "$ICONSET_DIRECTORY" ]]; then
        rm -rf "$ICONSET_DIRECTORY"
    fi
    mkdir -p "$ICONSET_DIRECTORY"
    sips -z 16 16 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_MASTER" --out "$ICONSET_DIRECTORY/icon_512x512.png" >/dev/null
    cp "$ICON_MASTER" "$ICONSET_DIRECTORY/icon_512x512@2x.png"
    swift "$PROJECT_DIRECTORY/scripts/make_icns.swift" "$ICONSET_DIRECTORY" "$ICON_FILE"
    rm -rf "$ICONSET_DIRECTORY"
fi

cp "$ICON_FILE" "$CONTENTS_DIRECTORY/Resources/RayPlacement.icns"
mkdir -p "$CONTENTS_DIRECTORY/Resources/Documentation"
cp "$PROJECT_DIRECTORY/docs/EXTENSION_AUTHORING_FOR_AI.md" "$CONTENTS_DIRECTORY/Resources/Documentation/EXTENSION_AUTHORING_FOR_AI.md"
cp "$PROJECT_DIRECTORY/docs/EXTENSIONS.md" "$CONTENTS_DIRECTORY/Resources/Documentation/EXTENSIONS.md"
cp "$PROJECT_DIRECTORY/docs/extension-manifest.schema.json" "$CONTENTS_DIRECTORY/Resources/Documentation/extension-manifest.schema.json"
mkdir -p "$CONTENTS_DIRECTORY/Resources/Documentation/starter-extension"
cp "$PROJECT_DIRECTORY/docs/starter-extension/manifest.json" "$CONTENTS_DIRECTORY/Resources/Documentation/starter-extension/manifest.json"
cp "$PROJECT_DIRECTORY/docs/starter-extension/README.md" "$CONTENTS_DIRECTORY/Resources/Documentation/starter-extension/README.md"
mkdir -p "$CONTENTS_DIRECTORY/Resources/Updater"
cp "$PROJECT_DIRECTORY/scripts/approved_lima_replacement.sh" "$CONTENTS_DIRECTORY/Resources/Updater/approved_lima_replacement.sh"
cp "$PROJECT_DIRECTORY/scripts/authorize_lima_update.applescript" "$CONTENTS_DIRECTORY/Resources/Updater/authorize_lima_update.applescript"
cp "$PROJECT_DIRECTORY/Packaging/RayPlacementLocalSigning.pem" "$CONTENTS_DIRECTORY/Resources/Updater/RayPlacementLocalSigning.pem"
mkdir -p "$CONTENTS_DIRECTORY/Resources/Emoji"
cp "$PROJECT_DIRECTORY/Packaging/Emoji/emoji-test.txt" "$CONTENTS_DIRECTORY/Resources/Emoji/emoji-test.txt"
if [[ ! -d "$BUNDLED_EXTENSIONS_DIRECTORY" ]]; then
    echo "The bundled extensions directory is missing."
    exit 1
fi
ditto "$BUNDLED_EXTENSIONS_DIRECTORY" "$CONTENTS_DIRECTORY/Resources/BundledExtensions"
chmod 755 "$CONTENTS_DIRECTORY/MacOS/Lima"
plutil -lint "$CONTENTS_DIRECTORY/Info.plist" >/dev/null
if [[ "${RAYPLACEMENT_DISABLE_LOCAL_SIGNING:-0}" == "1" ]]; then
    codesign --force --deep --sign - "$APP_DIRECTORY"
    echo "Warning: local signing was disabled; this build is ad-hoc signed."
elif [[ -f "$LOCAL_SIGNING_KEYCHAIN" && -f "$LOCAL_SIGNING_PASSWORD" ]]; then
    KEYCHAIN_PASSWORD="$(<"$LOCAL_SIGNING_PASSWORD")"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOCAL_SIGNING_KEYCHAIN"
    LOCAL_SIGNING_HASH="$(security find-identity -v -p codesigning "$LOCAL_SIGNING_KEYCHAIN" | awk -v identity="$LOCAL_SIGNING_IDENTITY" 'index($0, "\"" identity "\"") { print $2; exit }')"
    if [[ -n "$LOCAL_SIGNING_HASH" ]]; then
        ORIGINAL_USER_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}" )
        restore_signing_search_list() {
            security list-keychains -d user -s "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null
        }
        trap restore_signing_search_list EXIT INT TERM
        security list-keychains -d user -s "$LOCAL_SIGNING_KEYCHAIN" "${ORIGINAL_USER_KEYCHAINS[@]}"
        codesign \
            --force \
            --deep \
            --sign "$LOCAL_SIGNING_HASH" \
            "$APP_DIRECTORY"
        restore_signing_search_list
        trap - EXIT INT TERM
        echo "Signed with the stable RayPlacement local identity."
    elif [[ "${RAYPLACEMENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
        echo "RayPlacement's local signing identity exists but is not trusted for code signing."
        exit 1
    else
        codesign --force --deep --sign - "$APP_DIRECTORY"
        echo "Warning: the local identity is not trusted yet; this build is ad-hoc signed."
    fi
else
    if [[ "${RAYPLACEMENT_REQUIRE_STABLE_SIGNING:-0}" == "1" ]]; then
        echo "Stable signing is required. Run scripts/setup_local_signing.sh first."
        exit 1
    fi
    codesign --force --deep --sign - "$APP_DIRECTORY"
    echo "Warning: ad-hoc signing can make macOS forget Accessibility approval after a rebuild."
fi
if [[ "${RAYPLACEMENT_SKIP_PACKAGING_VERIFICATION:-0}" != "1" ]]; then
    RAYPLACEMENT_MODEL_FREE_UPDATE="$MODEL_FREE_UPDATE_BUILD" "$PROJECT_DIRECTORY/scripts/verify_liamflow_app.sh" "$APP_DIRECTORY"
fi

echo "Packaged: $APP_DIRECTORY"
