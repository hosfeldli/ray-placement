#!/bin/zsh
# Offline tests for the release metadata, stable update feed, Sparkle migration
# appcast, and strict content validators.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/lima-release-metadata-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

cat > "$TEMP_DIRECTORY/Lima-release.json" <<'JSON'
{
  "schemaVersion": 1,
  "tag": "v3.12.9",
  "version": "3.12.9",
  "build": "3129",
  "commit": "0123456789012345678901234567890123456789",
  "releaseUrl": "https://github.com/hosfeldli/ray-placement/releases/tag/v3.12.9",
  "updateUrl": "https://github.com/hosfeldli/ray-placement/releases/download/v3.12.9/Lima-Update.zip",
  "generatedAt": "2026-09-09T00:00:00Z",
  "update": { "name": "Lima-Update.zip", "bytes": 123, "sha256": "0123456789012345678901234567890123456789012345678901234567890123" },
  "dmg": { "name": "Lima.dmg", "bytes": 456, "sha256": "0123456789012345678901234567890123456789012345678901234567890123" }
}
JSON

"$SCRIPT_DIRECTORY/generate_update_feed.sh" \
    --metadata "$TEMP_DIRECTORY/Lima-release.json" \
    --output "$TEMP_DIRECTORY/latest.json"
"$SCRIPT_DIRECTORY/generate_sparkle_appcast.sh" \
    --metadata "$TEMP_DIRECTORY/Lima-release.json" \
    --output "$TEMP_DIRECTORY/appcast.xml"

jq -e '
    .schemaVersion == 1 and
    .tag == "v3.12.9" and
    .version == "3.12.9" and
    .updateDigest == "sha256:0123456789012345678901234567890123456789012345678901234567890123" and
    .updateSize == 123 and
    (.update | startswith("https://"))
' "$TEMP_DIRECTORY/latest.json" >/dev/null

python3 - "$TEMP_DIRECTORY/appcast.xml" <<'PY'
import sys
from xml.etree import ElementTree
root = ElementTree.parse(sys.argv[1]).getroot()
enclosure = root.find('.//enclosure')
assert enclosure is not None
assert enclosure.attrib['length'] == '123'
assert any(k.endswith('}sha256') for k in enclosure.attrib)
PY

LIMA_PROJECT_DIRECTORY="$SCRIPT_DIRECTORY/.."
source "$SCRIPT_DIRECTORY/release_common.sh"
release_validate_distribution_content \
    "$TEMP_DIRECTORY/latest.json" \
    "$TEMP_DIRECTORY/appcast.xml" \
    v3.12.9 \
    0123456789012345678901234567890123456789012345678901234567890123 \
    123

jq '.updateDigest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
    "$TEMP_DIRECTORY/latest.json" > "$TEMP_DIRECTORY/tampered.json"
if release_validate_distribution_content \
    "$TEMP_DIRECTORY/tampered.json" \
    "$TEMP_DIRECTORY/appcast.xml" \
    v3.12.9 \
    0123456789012345678901234567890123456789012345678901234567890123 \
    123; then
    print -u2 'Tampered update feed was accepted.'
    exit 1
fi

print 'Release metadata generators and content validation passed.'
