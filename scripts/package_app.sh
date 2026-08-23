#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
SCRATCH_DIRECTORY="$PROJECT_DIRECTORY/.build"
MODULE_CACHE_DIRECTORY="$SCRATCH_DIRECTORY/module-cache"
APP_DIRECTORY="$PROJECT_DIRECTORY/build/RayPlacement.app"
CONTENTS_DIRECTORY="$APP_DIRECTORY/Contents"
ICON_MASTER="$PROJECT_DIRECTORY/Packaging/AppIcon-master.png"
ICON_FILE="$PROJECT_DIRECTORY/Packaging/RayPlacement.icns"
HARPER_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Harper"
COEDIT_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/CoEdit"
QWEN_DIRECTORY="$PROJECT_DIRECTORY/Packaging/Vendor/Qwen"
QWEN_ASSEMBLER="$PROJECT_DIRECTORY/scripts/assemble_qwen_model.sh"
USER_HOME_DIRECTORY="${HOME:?The current user home folder is unavailable}"
LOCAL_SIGNING_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Signing"
LOCAL_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIRECTORY/RayPlacementSigning.keychain-db"
LOCAL_SIGNING_PASSWORD="$LOCAL_SIGNING_DIRECTORY/keychain-password"
LOCAL_SIGNING_IDENTITY="RayPlacement Local Code Signing"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIRECTORY"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIRECTORY"

mkdir -p "$MODULE_CACHE_DIRECTORY"
"$QWEN_ASSEMBLER"
swift build --configuration release --disable-sandbox --scratch-path "$SCRATCH_DIRECTORY"
BIN_DIRECTORY="$(swift build --configuration release --disable-sandbox --scratch-path "$SCRATCH_DIRECTORY" --show-bin-path)"

if [[ -d "$APP_DIRECTORY" ]]; then
    rm -rf "$APP_DIRECTORY"
fi
mkdir -p "$CONTENTS_DIRECTORY/MacOS" "$CONTENTS_DIRECTORY/Resources"

cp "$BIN_DIRECTORY/RayPlacement" "$CONTENTS_DIRECTORY/MacOS/RayPlacement"
cp "$PROJECT_DIRECTORY/Packaging/Info.plist" "$CONTENTS_DIRECTORY/Info.plist"

if [[ ! -x "$HARPER_DIRECTORY/harper-cli" || ! -x "$COEDIT_DIRECTORY/node" || ! -f "$COEDIT_DIRECTORY/runner.mjs" || ! -d "$COEDIT_DIRECTORY/model" || ! -d "$COEDIT_DIRECTORY/node_modules" || ! -x "$QWEN_DIRECTORY/runtime/llama-cli" || ! -f "$QWEN_DIRECTORY/Qwen3-1.7B-Q8_0.gguf" ]]; then
    echo "Bundled writing provider assets are missing. Run scripts/fetch_vendor_assets.sh and prepare the CoEdit runtime first."
    exit 1
fi
mkdir -p "$CONTENTS_DIRECTORY/Resources/Tools" "$CONTENTS_DIRECTORY/Resources/Licenses"
cp "$HARPER_DIRECTORY/harper-cli" "$CONTENTS_DIRECTORY/Resources/Tools/harper-cli"
cp "$HARPER_DIRECTORY/LICENSE" "$CONTENTS_DIRECTORY/Resources/Licenses/Harper-LICENSE"
ditto "$COEDIT_DIRECTORY" "$CONTENTS_DIRECTORY/Resources/CoEdit"
ditto "$QWEN_DIRECTORY" "$CONTENTS_DIRECTORY/Resources/Qwen"
rm -rf "$CONTENTS_DIRECTORY/Resources/Qwen/ModelParts"
chmod 755 "$CONTENTS_DIRECTORY/Resources/Tools/harper-cli" "$CONTENTS_DIRECTORY/Resources/CoEdit/node" "$CONTENTS_DIRECTORY/Resources/Qwen/runtime/llama-cli"

swift "$PROJECT_DIRECTORY/scripts/make_icon.swift" "$ICON_MASTER"
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

cp "$ICON_FILE" "$CONTENTS_DIRECTORY/Resources/RayPlacement.icns"
chmod 755 "$CONTENTS_DIRECTORY/MacOS/RayPlacement"
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
"$PROJECT_DIRECTORY/scripts/verify_app.sh" "$APP_DIRECTORY"

echo "Packaged: $APP_DIRECTORY"
