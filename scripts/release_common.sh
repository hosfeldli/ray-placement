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
        --arg teamIdentifier "$LIMA_RELEASE_TEAM_IDENTIFIER" \
        --arg certificateSHA256 "${LIMA_RELEASE_CERTIFICATE_SHA256:l}" \
        --arg updateSHA256 "$(shasum -a 256 "$update" | awk '{print $1}')" \
        --arg dmgSHA256 "$(shasum -a 256 "$dmg" | awk '{print $1}')" \
        --argjson updateBytes "$(stat -f %z "$update")" \
        --argjson dmgBytes "$(stat -f %z "$dmg")" \
        '{schemaVersion: 1, tag: $tag, version: $version, build: $build, commit: $commit, signingMode: $signingMode, signingIdentity: $signingIdentity, teamIdentifier: $teamIdentifier, certificateSHA256: $certificateSHA256, update: {name: "Lima-Update.zip", bytes: $updateBytes, sha256: $updateSHA256}, dmg: {name: "Lima.dmg", bytes: $dmgBytes, sha256: $dmgSHA256}}' \
        > "$metadata"
    chmod 600 "$metadata"
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
    tree_status="$(git -C "$LIMA_PROJECT_DIRECTORY" status --porcelain)
"
    [[ -z "$tree_status" ]] || {
        print -u2 "The working tree must be clean for this release phase."
        git -C "$LIMA_PROJECT_DIRECTORY" status --short >&2
        return 1
    }
}
