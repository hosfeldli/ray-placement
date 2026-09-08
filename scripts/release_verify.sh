#!/bin/zsh
# Verify local artifacts and/or the remote GitHub release before publication.
# Remote-only mode can verify an older published tag without requiring the
# current checkout to carry that same version; it remains strictly read-only.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"
TAG=""
REMOTE_ONLY=0

usage() {
    cat <<USAGE
Usage: release_verify.sh [--tag vX.Y.Z] [--remote-only]

Without --remote-only, verifies the local signed app, DMG, update archive,
checksums, source metadata, and the remote release assets. With --remote-only,
verifies the remote checksum files, API digests, exact release assets, and
absence of temporary DMG parts. This command never publishes.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2;;
        --remote-only) REMOTE_ONLY=1; shift;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done

[[ -n "$TAG" ]] || TAG="$(release_default_tag)"
release_validate_tag "$TAG"
DIST="$PROJECT_DIRECTORY/dist"

if (( ! REMOTE_ONLY )); then
    release_assert_tag_matches_source "$TAG"
    for artifact in Lima-Update.zip Lima-Update.sha256 Lima.dmg Lima.dmg.sha256 Lima-release.json; do
        [[ -f "$DIST/$artifact" ]] || { print -u2 "Missing $DIST/$artifact."; exit 1; }
    done
    (
        cd "$DIST"
        shasum -a 256 --check Lima-Update.sha256
        shasum -a 256 --check Lima.dmg.sha256
    )
    lima_release_validate_signing_policy
    lima_release_export_packaging_policy
    RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$SCRIPT_DIRECTORY/verify_liamflow_app.sh" "$PROJECT_DIRECTORY/build/Lima.app"
    RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$SCRIPT_DIRECTORY/verify_liamflow_dmg.sh" "$DIST/Lima.dmg"
    [[ "$(jq -er '.tag' "$DIST/Lima-release.json")" == "$TAG" ]] || { print -u2 'Release metadata tag mismatch.'; exit 1; }
    [[ "$(jq -er '.version' "$DIST/Lima-release.json")" == "$(release_version)" ]] || { print -u2 'Release metadata version mismatch.'; exit 1; }
    [[ "$(jq -er '.build' "$DIST/Lima-release.json")" == "$(release_build_number)" ]] || { print -u2 'Release metadata build mismatch.'; exit 1; }
    [[ "$(jq -er '.commit' "$DIST/Lima-release.json")" == "$(git -C "$PROJECT_DIRECTORY" rev-parse HEAD)" ]] || { print -u2 'Release metadata commit mismatch.'; exit 1; }
    [[ "$(jq -er '.signingMode' "$DIST/Lima-release.json")" == "$LIMA_RELEASE_SIGNING_MODE" ]] || { print -u2 'Release metadata signing mode mismatch.'; exit 1; }
    [[ "$(jq -er '.certificateSHA256' "$DIST/Lima-release.json")" == "${LIMA_RELEASE_CERTIFICATE_SHA256:l}" ]] || { print -u2 'Release metadata certificate mismatch.'; exit 1; }
    update_sha="$(jq -er '.update.sha256' "$DIST/Lima-release.json")"
    dmg_sha="$(jq -er '.dmg.sha256' "$DIST/Lima-release.json")"
else
    checksum_directory="$(mktemp -d "${TMPDIR%/}/lima-remote-checksums.XXXXXX")"
    trap 'rm -rf "$checksum_directory"' EXIT
    gh release download "$TAG" --pattern 'Lima-Update.sha256' --pattern 'Lima.dmg.sha256' --dir "$checksum_directory" >/dev/null
    update_sha="$(awk '$1 ~ /^[[:xdigit:]]{64}$/ && $2 == "Lima-Update.zip" {print tolower($1); exit}' "$checksum_directory/Lima-Update.sha256")"
    [[ -n "$update_sha" ]] || update_sha="$(awk '$1 ~ /^[[:xdigit:]]{64}$/ && $2 == "*Lima-Update.zip" {print tolower($1); exit}' "$checksum_directory/Lima-Update.sha256")"
    dmg_sha="$(awk '$1 ~ /^[[:xdigit:]]{64}$/ && $2 == "Lima.dmg" {print tolower($1); exit}' "$checksum_directory/Lima.dmg.sha256")"
    [[ -n "$dmg_sha" ]] || dmg_sha="$(awk '$1 ~ /^[[:xdigit:]]{64}$/ && $2 == "*Lima.dmg" {print tolower($1); exit}' "$checksum_directory/Lima.dmg.sha256")"
    [[ -n "$update_sha" && -n "$dmg_sha" ]] || { print -u2 'Remote checksum assets do not contain filename-matched SHA-256 values.'; exit 1; }
fi

[[ "$update_sha" =~ '^[[:xdigit:]]{64}$' && "$dmg_sha" =~ '^[[:xdigit:]]{64}$' ]] || {
    print -u2 'Release checksum assets do not contain valid SHA-256 values.'
    exit 1
}

# Published releases are valid verification targets. Only the stage/publish
# phases require a draft and therefore may change release assets/state.
release_state="$(gh release view "$TAG" --json isDraft --jq .isDraft)"
[[ "$release_state" == true || "$release_state" == false ]] || { print -u2 "Could not determine release state for $TAG."; exit 1; }

for asset in Lima-Update.zip Lima.dmg Lima-Update.sha256 Lima.dmg.sha256; do
    api_url="$(release_remote_asset_api_url "$TAG" "$asset")"
    [[ -n "$api_url" ]] || { print -u2 "$asset is missing from $TAG."; exit 1; }
    actual="$(gh api "$api_url" --jq '.digest // empty')"
    [[ "$actual" == sha256:* ]] || { print -u2 "$asset has no GitHub API SHA-256 digest."; exit 1; }
    case "$asset" in
        Lima-Update.zip) expected="$update_sha";;
        Lima.dmg) expected="$dmg_sha";;
        Lima-Update.sha256)
            if (( REMOTE_ONLY )); then expected="$(shasum -a 256 "$checksum_directory/Lima-Update.sha256" | awk '{print tolower($1)}')";
            else expected="$(shasum -a 256 "$DIST/Lima-Update.sha256" | awk '{print tolower($1)}')"; fi
            ;;
        Lima.dmg.sha256)
            if (( REMOTE_ONLY )); then expected="$(shasum -a 256 "$checksum_directory/Lima.dmg.sha256" | awk '{print tolower($1)}')";
            else expected="$(shasum -a 256 "$DIST/Lima.dmg.sha256" | awk '{print tolower($1)}')"; fi
            ;;
    esac
    [[ "$actual" == "sha256:${expected:l}" ]] || {
        print -u2 "$asset remote digest mismatch: expected sha256:${expected:l}, got $actual."
        exit 1
    }
    print "$asset remote digest verified: $actual"
done

if release_remote_asset_names "$TAG" | grep -E '^Lima\.dmg\.part-' >/dev/null 2>&1; then
    print -u2 'Temporary DMG parts remain on the release; refusing verification.'
    exit 1
fi
print "Release verified: $TAG ($([[ "$release_state" == true ]] && print draft || print published))"
