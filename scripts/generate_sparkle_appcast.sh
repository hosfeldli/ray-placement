#!/bin/zsh
# Generate a real Sparkle 2 appcast from the normal Sparkle update archive.
# Lima-Update.zip remains the legacy custom-updater artifact; this script only
# consumes Lima-Sparkle.zip or another archive containing Lima.app directly.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
SPARKLE_GENERATE_APPCAST="${RAYPLACEMENT_SPARKLE_GENERATE_APPCAST:-$PROJECT_DIRECTORY/.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"
SPARKLE_SIGN_UPDATE="${RAYPLACEMENT_SPARKLE_SIGN_UPDATE:-$PROJECT_DIRECTORY/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
METADATA=""
OUTPUT=""
ARCHIVE=""
KEY_FILE="${SPARKLE_EDDSA_PRIVATE_KEY_FILE:-}"
PRIVATE_KEY="${SPARKLE_EDDSA_PRIVATE_KEY:-}"

usage() {
    print 'Usage: generate_sparkle_appcast.sh --metadata dist/Lima-release.json --output dist/appcast.xml --archive dist/Lima-Sparkle.zip [--key-file file]'
}

while (( $# > 0 )); do
    case "$1" in
        --metadata) METADATA="${2:?--metadata requires a file}"; shift 2;;
        --output) OUTPUT="${2:?--output requires a file}"; shift 2;;
        --archive) ARCHIVE="${2:?--archive requires a file}"; shift 2;;
        --key-file) KEY_FILE="${2:?--key-file requires a file}"; shift 2;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done

[[ -f "$METADATA" && -n "$OUTPUT" && -f "$ARCHIVE" ]] || {
    print -u2 'Metadata, output, and a normal Sparkle archive are required.'
    exit 2
}
[[ -x "$SPARKLE_GENERATE_APPCAST" ]] || {
    print -u2 "Sparkle generate_appcast was not found at $SPARKLE_GENERATE_APPCAST. Resolve Sparkle 2.9.6 first."
    exit 1
}
[[ -x "$SPARKLE_SIGN_UPDATE" ]] || {
    print -u2 "Sparkle sign_update was not found at $SPARKLE_SIGN_UPDATE. Resolve Sparkle 2.9.6 first."
    exit 1
}

version="$(jq -er '.version' "$METADATA")"
build="$(jq -er '.build' "$METADATA")"
release_url="$(jq -er '.releaseUrl' "$METADATA")"
sparkle_update_url="$(jq -er '.sparkleUpdateUrl' "$METADATA")"
sparkle_update_name="$(jq -er '.sparkleUpdate.name' "$METADATA")"
[[ "$sparkle_update_name" == "${ARCHIVE:t}" ]] || {
    print -u2 "Metadata Sparkle archive $sparkle_update_name does not match ${ARCHIVE:t}."
    exit 1
}
[[ "$build" =~ '^[0-9]+$' ]] || { print -u2 "Invalid Sparkle build number: $build"; exit 1; }

if [[ -z "$KEY_FILE" && -z "$PRIVATE_KEY" ]]; then
    print -u2 'A real Sparkle EdDSA private key is required; refusing to emit an unsigned or placeholder appcast.'
    print -u2 'Use --key-file locally or SPARKLE_EDDSA_PRIVATE_KEY in CI.'
    exit 1
fi

ARCHIVE_DIRECTORY="$(mktemp -d "${TMPDIR%/}/lima-sparkle-appcast.XXXXXX")"
SIGNATURE_OUTPUT="$(mktemp "${TMPDIR%/}/lima-sparkle-signature.XXXXXX")"
cleanup() {
    rm -rf -- "$ARCHIVE_DIRECTORY"
    rm -f -- "$SIGNATURE_OUTPUT"
}
trap cleanup EXIT

ditto "$ARCHIVE" "$ARCHIVE_DIRECTORY/${ARCHIVE:t}"

run_with_key() {
    local tool="$1"
    shift
    if [[ -n "$KEY_FILE" ]]; then
        "$tool" --ed-key-file "$KEY_FILE" "$@"
    else
        printf '%s' "$PRIVATE_KEY" | "$tool" --ed-key-file - "$@"
    fi
}

# generate_appcast supplies Sparkle's canonical XML structure and derives
# sparkle:version from CFBundleVersion. Sparkle 2.9.6 does not reliably add the
# enclosure signature itself, so the archive is signed explicitly below.
run_with_key "$SPARKLE_GENERATE_APPCAST" \
    --disable-signing-warning \
    --download-url-prefix "${sparkle_update_url%/*}/" \
    --link "$release_url" \
    --versions "$build" \
    -o "$ARCHIVE_DIRECTORY/appcast.xml" \
    "$ARCHIVE_DIRECTORY"

# -p emits only the archive signature. Compute length from the exact archive
# that will be published rather than parsing human-readable tool output.
run_with_key "$SPARKLE_SIGN_UPDATE" -p "$ARCHIVE_DIRECTORY/${ARCHIVE:t}" > "$SIGNATURE_OUTPUT"
archive_signature="$(tr -d '\r\n' < "$SIGNATURE_OUTPUT")"
archive_length="$(/usr/bin/stat -f %z "$ARCHIVE_DIRECTORY/${ARCHIVE:t}")"
[[ "$archive_signature" =~ '^[A-Za-z0-9+/=]{80,}$' && "$archive_length" =~ '^[0-9]+$' ]] || {
    print -u2 'Sparkle did not return a valid archive EdDSA signature.'
    exit 1
}
run_with_key "$SPARKLE_SIGN_UPDATE" --verify "$ARCHIVE_DIRECTORY/${ARCHIVE:t}" "$archive_signature" >/dev/null

python3 - "$ARCHIVE_DIRECTORY/appcast.xml" "$sparkle_update_url" "$archive_signature" "$archive_length" <<'PY'
import sys
from xml.etree import ElementTree

path, expected_url, signature, length = sys.argv[1:]
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ElementTree.register_namespace("sparkle", ns)
root = ElementTree.parse(path).getroot()
enclosure = root.find('./channel/item/enclosure')
if enclosure is None or enclosure.get('url') != expected_url:
    raise SystemExit('Sparkle appcast enclosure is missing or has the wrong URL')
enclosure.set(f'{{{ns}}}edSignature', signature)
enclosure.set('length', length)
ElementTree.ElementTree(root).write(path, encoding='utf-8', xml_declaration=True)
PY

# Sign the completed feed. sign_update embeds a sparkle-signatures comment in
# the XML; this is distinct from the enclosure signature above.
run_with_key "$SPARKLE_SIGN_UPDATE" --disable-signing-warning "$ARCHIVE_DIRECTORY/appcast.xml" >/dev/null
run_with_key "$SPARKLE_SIGN_UPDATE" --verify "$ARCHIVE_DIRECTORY/appcast.xml" >/dev/null

mkdir -p "${OUTPUT:h}"
cp "$ARCHIVE_DIRECTORY/appcast.xml" "$OUTPUT"

python3 - "$OUTPUT" "$sparkle_update_url" "$build" "$version" "$archive_length" <<'PY'
import sys
from xml.etree import ElementTree

appcast, expected_url, expected_build, expected_version, expected_length = sys.argv[1:]
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ElementTree.parse(appcast).getroot()
item = root.find('./channel/item')
if item is None:
    raise SystemExit('Sparkle appcast has no update item')
if item.findtext(f'{{{ns}}}version') != expected_build:
    raise SystemExit('Sparkle appcast build does not match CFBundleVersion')
if item.findtext(f'{{{ns}}}shortVersionString') != expected_version:
    raise SystemExit('Sparkle appcast short version does not match CFBundleShortVersionString')
enclosure = item.find('enclosure')
if enclosure is None or enclosure.get('url') != expected_url:
    raise SystemExit('Sparkle appcast enclosure URL does not match Lima-Sparkle.zip')
if enclosure.get('length') != expected_length:
    raise SystemExit('Sparkle appcast archive length does not match Lima-Sparkle.zip')
if not enclosure.get(f'{{{ns}}}edSignature'):
    raise SystemExit('Sparkle appcast enclosure has no EdDSA signature')
raw = open(appcast, encoding='utf-8').read()
if 'sparkle-signatures:' not in raw or 'edSignature:' not in raw:
    raise SystemExit('Sparkle appcast feed signature is missing')
PY
