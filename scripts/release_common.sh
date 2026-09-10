#!/bin/zsh
# Common functions for the staged Lima release commands.
# Callers must set LIMA_PROJECT_DIRECTORY before sourcing this file.

RELEASE_COMMON_DIRECTORY="${${(%):-%x}:A:h}"
source "$RELEASE_COMMON_DIRECTORY/release_config.sh"

release_require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        print -u2 "Missing required command: $1"
        return 1
    }
}

release_project_file() {
    print -r -- "$LIMA_PROJECT_DIRECTORY/$1"
}

release_version() {
    lima_release_version_from_plist "$(release_project_file Packaging/Info.plist)"
}

release_build_number() {
    lima_release_build_from_plist "$(release_project_file Packaging/Info.plist)"
}

release_default_tag() {
    print -r -- "v$(release_version)"
}

release_validate_tag() {
    local tag="$1"
    [[ "$tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
        print -u2 "Invalid release tag: $tag (expected vX.Y.Z)."
        return 1
    }
}

release_assert_tag_matches_source() {
    local tag="$1"
    release_validate_tag "$tag"
    [[ "${tag#v}" == "$(release_version)" ]] || {
        print -u2 "Release tag $tag does not match source version $(release_version)."
        return 1
    }
    [[ "$(release_build_number)" == "$(lima_release_build_number "${tag#v}")" ]] || {
        print -u2 "CFBundleVersion $(release_build_number) does not match $tag."
        return 1
    }
}

# A release artifact must be built from the immutable tag commit, never from
# whichever commit happens to be checked out on the long-lived release branch.
# CI checkouts and local release rehearsals both use this helper when the tag is
# available locally.
release_assert_exact_tag_identity() {
    local tag="$1"
    release_validate_tag "$tag"
    local head="$(git -C "$LIMA_PROJECT_DIRECTORY" rev-parse HEAD)"
    local tag_commit="$(git -C "$LIMA_PROJECT_DIRECTORY" rev-list -n1 "$tag" 2>/dev/null || true)"
    [[ -n "$tag_commit" ]] || {
        print -u2 "Immutable release tag is not available locally: $tag"
        return 1
    }
    [[ "$head" == "$tag_commit" ]] || {
        print -u2 "Release source identity mismatch: HEAD $head is not $tag $tag_commit."
        return 1
    }
    print "Exact source identity verified: $tag ($head)"
}

release_metadata_file() {
    local tag="$1"
    print -r -- "$(release_project_file "dist/Lima-release.json")"
}

release_read_metadata() {
    local key="$1"
    local metadata="$(release_metadata_file "${2:-}")"
    [[ -f "$metadata" ]] || {
        print -u2 "Release metadata is missing: $metadata"
        return 1
    }
    jq -er --arg key "$key" '.[$key] // empty' "$metadata"
}

release_write_metadata() {
    local tag="$1"
    local metadata="$(release_metadata_file "$tag")"
    local dist="$(release_project_file dist)"
    local update="$dist/Lima-Update.zip"
    local dmg="$dist/Lima.dmg"
    local commit="$(git -C "$LIMA_PROJECT_DIRECTORY" rev-parse HEAD)"
    jq -n \
        --arg tag "$tag" \
        --arg version "$(release_version)" \
        --arg build "$(release_build_number)" \
        --arg commit "$commit" \
        --arg signingMode "$LIMA_RELEASE_SIGNING_MODE" \
        --arg signingIdentity "$LIMA_RELEASE_SIGNING_IDENTITY" \
        --arg certificateSHA256 "${LIMA_RELEASE_CERTIFICATE_SHA256:l}" \
        --arg releaseURL "https://github.com/hosfeldli/ray-placement/releases/tag/$tag" \
        --arg updateURL "https://github.com/hosfeldli/ray-placement/releases/download/$tag/Lima-Update.zip" \
        --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg updateSHA256 "$(shasum -a 256 "$update" | awk '{print $1}')" \
        --arg dmgSHA256 "$(shasum -a 256 "$dmg" | awk '{print $1}')" \
        --argjson updateBytes "$(stat -f %z "$update")" \
        --argjson dmgBytes "$(stat -f %z "$dmg")" \
        '{schemaVersion: 1, tag: $tag, version: $version, build: $build, commit: $commit, signingMode: $signingMode, signingIdentity: $signingIdentity, certificateSHA256: $certificateSHA256, releaseUrl: $releaseURL, updateUrl: $updateURL, generatedAt: $generatedAt, update: {name: "Lima-Update.zip", bytes: $updateBytes, sha256: $updateSHA256}, dmg: {name: "Lima.dmg", bytes: $dmgBytes, sha256: $dmgSHA256}}' \
        > "$metadata"
    chmod 600 "$metadata"
}

release_generate_distribution_metadata() {
    local tag="$1"
    local metadata="$(release_metadata_file "$tag")"
    local dist="$(release_project_file dist)"
    [[ -f "$metadata" ]] || { print -u2 "Release metadata is missing: $metadata"; return 1; }
    "$RELEASE_COMMON_DIRECTORY/generate_update_feed.sh" --metadata "$metadata" --output "$dist/latest.json"
    "$RELEASE_COMMON_DIRECTORY/generate_sparkle_appcast.sh" --metadata "$metadata" --output "$dist/appcast.xml"
    chmod 600 "$dist/latest.json" "$dist/appcast.xml"
}

release_validate_distribution_content() {
    local feed="$1"
    local appcast="$2"
    local tag="$3"
    local update_sha="$4"
    local update_bytes="$5"
    local version="${tag#v}"
    local release_url="https://github.com/hosfeldli/ray-placement/releases/tag/$tag"
    local update_url="https://github.com/hosfeldli/ray-placement/releases/download/$tag/Lima-Update.zip"

    [[ -f "$feed" && -f "$appcast" ]] || {
        print -u2 'Update feed and appcast files are required for content validation.'
        return 1
    }

    jq -e \
        --arg tag "$tag" \
        --arg version "$version" \
        --arg release_url "$release_url" \
        --arg update_url "$update_url" \
        --arg update_digest "sha256:${update_sha:l}" \
        --argjson update_size "$update_bytes" \
        '(.schemaVersion == 1) and
         (.tag == $tag) and
         (.version == $version) and
         (.releaseUrl == $release_url) and
         (.update == $update_url) and
         (.updateDigest == $update_digest) and
         (.updateSize == $update_size) and
         (.publication.channel == "stable") and
         (.publication.tag == $tag) and
         (.publication.commit | strings | length == 40)' \
        "$feed" >/dev/null || {
        print -u2 'Stable update feed content does not match the verified release.'
        return 1
    }

    python3 - "$appcast" "$tag" "$version" "$update_url" "$update_sha" "$update_bytes" "$release_url" <<'APPCAST_VALIDATOR'
import sys
from xml.etree import ElementTree

appcast, tag, version, update_url, update_sha, update_bytes, release_url = sys.argv[1:]
ns = {
    "sparkle": "http://www.andymatushek.org/xml-namespaces/sparkle",
    "lima": "https://www.liamhosfeld.com/xml-namespaces/lima",
}
root = ElementTree.parse(appcast).getroot()
if root.tag != "rss":
    raise SystemExit("Appcast root is not RSS")
channel = root.find("channel")
if channel is None:
    raise SystemExit("Appcast channel is missing")
if (channel.findtext("title") or "") != "Lima Updates":
    raise SystemExit("Appcast title mismatch")
if (channel.findtext("link") or "") != release_url:
    raise SystemExit("Appcast release URL mismatch")
items = channel.findall("item")
if len(items) != 1:
    raise SystemExit("Appcast must contain exactly one release item")
item = items[0]
if item.get(f"{{{ns['sparkle']}}}version") != version:
    raise SystemExit("Appcast Sparkle version mismatch")
if item.get("version") != version:
    raise SystemExit("Appcast version mismatch")
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("Appcast enclosure is missing")
if enclosure.get("url") != update_url:
    raise SystemExit("Appcast update URL mismatch")
if enclosure.get("length") != update_bytes:
    raise SystemExit("Appcast update size mismatch")
if enclosure.get(f"{{{ns['lima']}}}sha256") != update_sha.lower():
    raise SystemExit("Appcast update digest mismatch")
if enclosure.get(f"{{{ns['lima']}}}signatureStatus") != "pending-sparkle-signature":
    raise SystemExit("Appcast signature migration marker is missing")
if f"{{{ns['sparkle']}}}edSignature" in enclosure.attrib:
    raise SystemExit("Unsigned migration appcast must not claim a Sparkle signature")
APPCAST_VALIDATOR
}

release_assert_distribution_metadata() {
    local tag="$1"
    local metadata="$(release_metadata_file "$tag")"
    local dist="$(release_project_file dist)"
    for file in "$dist/latest.json" "$dist/appcast.xml"; do
        [[ -f "$file" ]] || { print -u2 "Distribution metadata is missing: $file"; return 1; }
    done
    release_validate_distribution_content \
        "$dist/latest.json" \
        "$dist/appcast.xml" \
        "$tag" \
        "$(jq -er '.update.sha256' "$metadata")" \
        "$(jq -er '.update.bytes' "$metadata")"
}

release_remote_asset_api_url() {
    local tag="$1"
    local asset="$2"
    gh release view "$tag" --json assets --jq ".assets[] | select(.name == \"$asset\") | .apiUrl" 2>/dev/null | head -n 1
}

release_remote_asset_digest() {
    local tag="$1"
    local asset="$2"
    local api_url="$(release_remote_asset_api_url "$tag" "$asset")"
    [[ -n "$api_url" ]] || return 1
    gh api "$api_url" --jq '.digest // empty'
}

release_remote_asset_names() {
    local tag="$1"
    gh release view "$tag" --json assets --jq '.assets[].name'
}

release_upload_if_needed() {
    local tag="$1"
    local file="$2"
    local asset="${3:-${file:t}}"
    local expected="${4:-$(shasum -a 256 "$file" | awk '{print $1}')}"
    local actual=""
    actual="$(release_remote_asset_digest "$tag" "$asset" 2>/dev/null || true)"
    if [[ "$actual" == "sha256:${expected:l}" ]]; then
        print "Already verified remotely: $asset"
        return 0
    fi
    print "Uploading: $asset"
    gh release upload "$tag" "$file#$asset" --clobber
}

release_assert_draft() {
    local tag="$1"
    [[ "$(gh release view "$tag" --json isDraft --jq .isDraft)" == true ]] || {
        print -u2 "$tag is not a draft release; refusing to modify or replace it."
        return 1
    }
}

release_assert_clean_tree() {
    local tree_status
    tree_status="$(git -C "$LIMA_PROJECT_DIRECTORY" status --porcelain)"
    [[ -z "$tree_status" ]] || {
        print -u2 "The working tree must be clean for this release phase."
        git -C "$LIMA_PROJECT_DIRECTORY" status --short >&2
        return 1
    }
}
