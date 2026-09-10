#!/bin/zsh
# Exercise the real stable feed and Sparkle appcast generators with a tiny
# temporary Lima.app and real temporary EdDSA key material. The private key
# is never printed and all test material is removed on exit.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/lima-release-metadata-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

SPARKLE_BIN="$PROJECT_DIRECTORY/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/sign_update" ]] || {
    print -u2 'Sparkle 2.9.6 tools are required for the metadata test.'
    exit 1
}

APP="$TEMP_DIRECTORY/Lima.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.liam.lima</string>
<key>CFBundleName</key><string>Lima</string>
<key>CFBundleDisplayName</key><string>Lima</string>
<key>CFBundleExecutable</key><string>Lima</string>
<key>CFBundleShortVersionString</key><string>3.12.9</string>
<key>CFBundleVersion</key><string>3129</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/Lima"
chmod 755 "$APP/Contents/MacOS/Lima"
(cd "$TEMP_DIRECTORY" && ditto -c -k --sequesterRsrc --keepParent Lima.app Lima-Sparkle.zip)
SPARKLE_BYTES="$(/usr/bin/stat -f %z "$TEMP_DIRECTORY/Lima-Sparkle.zip")"
SPARKLE_SHA="$(shasum -a 256 "$TEMP_DIRECTORY/Lima-Sparkle.zip" | awk '{print $1}')"

cat > "$TEMP_DIRECTORY/Lima-release.json" <<JSON
{
  "schemaVersion": 1,
  "tag": "v3.12.9",
  "version": "3.12.9",
  "build": "3129",
  "commit": "0123456789012345678901234567890123456789",
  "signingMode": "self-signed-local",
  "signingIdentity": "RayPlacement Local Code Signing",
  "certificateSHA256": "20802e48a45cf483c1394cf57f319bce2b764289ff35e049a17ae60aeb62e8ca",
  "releaseUrl": "https://github.com/hosfeldli/ray-placement/releases/tag/v3.12.9",
  "updateUrl": "https://github.com/hosfeldli/ray-placement/releases/download/v3.12.9/Lima-Update.zip",
  "sparkleUpdateUrl": "https://github.com/hosfeldli/ray-placement/releases/download/v3.12.9/Lima-Sparkle.zip",
  "generatedAt": "2026-09-09T00:00:00Z",
  "update": { "name": "Lima-Update.zip", "bytes": 123, "sha256": "0123456789012345678901234567890123456789012345678901234567890123" },
  "sparkleUpdate": { "name": "Lima-Sparkle.zip", "bytes": $SPARKLE_BYTES, "sha256": "$SPARKLE_SHA" },
  "dmg": { "name": "Lima.dmg", "bytes": 456, "sha256": "0123456789012345678901234567890123456789012345678901234567890123" }
}
JSON

"$SCRIPT_DIRECTORY/generate_update_feed.sh" \
    --metadata "$TEMP_DIRECTORY/Lima-release.json" \
    --output "$TEMP_DIRECTORY/latest.json"

openssl rand -base64 32 | tr -d '\n' > "$TEMP_DIRECTORY/private.key"
"$SCRIPT_DIRECTORY/generate_sparkle_appcast.sh" \
    --metadata "$TEMP_DIRECTORY/Lima-release.json" \
    --output "$TEMP_DIRECTORY/appcast.xml" \
    --archive "$TEMP_DIRECTORY/Lima-Sparkle.zip" \
    --key-file "$TEMP_DIRECTORY/private.key"

jq -e '
    .schemaVersion == 1 and
    .tag == "v3.12.9" and
    .version == "3.12.9" and
    .updateDigest == "sha256:0123456789012345678901234567890123456789012345678901234567890123" and
    .updateSize == 123 and
    (.update | startswith("https://"))
' "$TEMP_DIRECTORY/latest.json" >/dev/null

python3 - "$TEMP_DIRECTORY/appcast.xml" "$TEMP_DIRECTORY/Lima-Sparkle.zip" <<'PY'
import sys
from xml.etree import ElementTree

appcast, archive = sys.argv[1:]
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
root = ElementTree.parse(appcast).getroot()
item = root.find('./channel/item')
assert item is not None
assert item.findtext(f'{{{ns}}}version') == '3129'
assert item.findtext(f'{{{ns}}}shortVersionString') == '3.12.9'
enclosure = item.find('enclosure')
assert enclosure is not None
assert enclosure.attrib['length'] == str(__import__('os').stat(archive).st_size)
assert enclosure.attrib[f'{{{ns}}}edSignature']
assert 'sparkle-signatures:' in open(appcast, encoding='utf-8').read()
PY

# The repository validator reads production metadata from dist. Point it at a
# temporary project-shaped directory so no release artifacts are touched.
TEST_PROJECT="$TEMP_DIRECTORY/project"
mkdir -p "$TEST_PROJECT/dist"
cp "$TEMP_DIRECTORY/Lima-release.json" "$TEST_PROJECT/dist/Lima-release.json"
cp "$TEMP_DIRECTORY/latest.json" "$TEST_PROJECT/dist/latest.json"
cp "$TEMP_DIRECTORY/appcast.xml" "$TEST_PROJECT/dist/appcast.xml"
LIMA_PROJECT_DIRECTORY="$TEST_PROJECT"
source "$SCRIPT_DIRECTORY/release_common.sh"
release_validate_distribution_content \
    "$TEMP_DIRECTORY/latest.json" \
    "$TEMP_DIRECTORY/appcast.xml" \
    v3.12.9 \
    0123456789012345678901234567890123456789012345678901234567890123 \
    123

if "$SCRIPT_DIRECTORY/generate_sparkle_appcast.sh" \
    --metadata "$TEMP_DIRECTORY/Lima-release.json" \
    --output "$TEMP_DIRECTORY/no-key.xml" \
    --archive "$TEMP_DIRECTORY/Lima-Sparkle.zip" >/dev/null 2>&1; then
    print -u2 'Unsigned Sparkle appcast generation unexpectedly succeeded.'
    exit 1
fi

print 'Release metadata generators and signed Sparkle appcast validation passed.'
