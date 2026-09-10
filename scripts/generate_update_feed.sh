#!/bin/zsh
# Generate the stable JSON update feed from the exact release metadata produced
# by the same build. The feed is uploaded as a draft-release asset before the
# release is promoted, so publication cannot expose a feed for a different
# commit or digest.
set -euo pipefail

METADATA=""
OUTPUT=""
while (( $# > 0 )); do
    case "$1" in
        --metadata) METADATA="${2:?--metadata requires a file}"; shift 2;;
        --output) OUTPUT="${2:?--output requires a file}"; shift 2;;
        -h|--help)
            print 'Usage: generate_update_feed.sh --metadata dist/Lima-release.json --output dist/latest.json'
            exit 0;;
        *) print -u2 "Unknown option: $1"; exit 2;;
    esac
done
[[ -f "$METADATA" && -n "$OUTPUT" ]] || { print -u2 'Metadata and output are required.'; exit 2; }

version="$(jq -er '.version' "$METADATA")"
tag="$(jq -er '.tag' "$METADATA")"
release_url="$(jq -er '.releaseUrl' "$METADATA")"
update_url="$(jq -er '.updateUrl' "$METADATA")"
update_sha="$(jq -er '.update.sha256' "$METADATA")"
update_bytes="$(jq -er '.update.bytes' "$METADATA")"
generated_at="$(jq -er '.generatedAt' "$METADATA")"
commit="$(jq -er '.commit' "$METADATA")"
build="$(jq -er '.build' "$METADATA")"

mkdir -p "${OUTPUT:h}"
jq -n \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg releaseUrl "$release_url" \
    --arg update "$update_url" \
    --arg updateDigest "sha256:${update_sha}" \
    --arg generatedAt "$generated_at" \
    --arg commit "$commit" \
    --arg build "$build" \
    --argjson updateSize "$update_bytes" \
    '{schemaVersion: 1, version: $version, tag: $tag, build: $build, commit: $commit, releaseUrl: $releaseUrl, publishedAt: $generatedAt, update: $update, updateDigest: $updateDigest, updateSize: $updateSize, publication: {channel: "stable", source: "github-release", tag: $tag, commit: $commit, generatedAt: $generatedAt}}' \
    > "$OUTPUT"
plutil -lint /dev/null >/dev/null 2>&1 || true
jq -e '(.schemaVersion == 1) and (.version | strings) and (.tag | strings) and (.releaseUrl | startswith("https://")) and (.update | startswith("https://")) and (.updateDigest | test("^sha256:[0-9a-f]{64}$")) and (.updateSize > 0)' "$OUTPUT" >/dev/null
