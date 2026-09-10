#!/bin/zsh
# Create/resume a draft release and upload verified assets. DMGs are always
# uploaded as parts and reassembled by GitHub Actions; direct large uploads are
# intentionally not attempted.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"
TAG=""
DRY_RUN=0
WAIT=1

usage() {
    cat <<USAGE
Usage: release_stage.sh [--tag vX.Y.Z] [--dry-run] [--no-wait]

The local artifacts must already exist. Normal mode creates or resumes a draft,
uploads the update/checksum assets, uploads DMG parts, and waits for verified
GitHub reassembly. It is safe to rerun after an interrupted upload.
USAGE
}
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2;;
        --dry-run) DRY_RUN=1; shift;;
        --no-wait) WAIT=0; shift;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done
[[ -n "$TAG" ]] || TAG="$(release_default_tag)"
release_validate_tag "$TAG"
DIST="$PROJECT_DIRECTORY/dist"
for artifact in Lima-Update.zip Lima-Update.sha256 Lima-Sparkle.zip Lima-Sparkle.sha256 Lima.dmg Lima.dmg.sha256 Lima-release.json latest.json appcast.xml; do
    [[ -f "$DIST/$artifact" ]] || { print -u2 "Missing $DIST/$artifact; run release_build.sh first."; exit 1; }
done
(
    cd "$DIST"
    shasum -a 256 --check Lima-Update.sha256
    shasum -a 256 --check Lima-Sparkle.sha256
    shasum -a 256 --check Lima.dmg.sha256
)

if (( DRY_RUN )); then
    print "Dry run: would create/resume draft $TAG, upload update/feed assets, split DMG into $LIMA_RELEASE_DMG_PART_SIZE parts, and run assemble-signed-dmg.yml."
    exit 0
fi

release_assert_tag_matches_source "$TAG"
release_assert_exact_tag_identity "$TAG"

release_assert_clean_tree
gh auth status >/dev/null
if gh release view "$TAG" >/dev/null 2>&1; then
    release_assert_draft "$TAG"
else
    if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
        print -u2 "Remote tag $TAG already exists without a draft release; refusing to create a conflicting release."
        exit 1
    fi
    target="$(git -C "$PROJECT_DIRECTORY" rev-parse HEAD)"
    gh release create "$TAG" --draft --target "$target" --title "Lima $TAG" --generate-notes
fi

release_upload_if_needed "$TAG" "$DIST/Lima-Update.zip" Lima-Update.zip "$(jq -er '.update.sha256' "$DIST/Lima-release.json")"
release_upload_if_needed "$TAG" "$DIST/Lima-Update.sha256" Lima-Update.sha256 "$(shasum -a 256 "$DIST/Lima-Update.sha256" | awk '{print $1}')"
release_upload_if_needed "$TAG" "$DIST/Lima-Sparkle.zip" Lima-Sparkle.zip "$(jq -er '.sparkleUpdate.sha256' "$DIST/Lima-release.json")"
release_upload_if_needed "$TAG" "$DIST/Lima-Sparkle.sha256" Lima-Sparkle.sha256 "$(shasum -a 256 "$DIST/Lima-Sparkle.sha256" | awk '{print $1}')"
release_upload_if_needed "$TAG" "$DIST/Lima.dmg.sha256" Lima.dmg.sha256 "$(shasum -a 256 "$DIST/Lima.dmg.sha256" | awk '{print $1}')"
release_upload_if_needed "$TAG" "$DIST/latest.json" latest.json "$(shasum -a 256 "$DIST/latest.json" | awk '{print $1}')"
release_upload_if_needed "$TAG" "$DIST/appcast.xml" appcast.xml "$(shasum -a 256 "$DIST/appcast.xml" | awk '{print $1}')"

remote_dmg_url="$(release_remote_asset_api_url "$TAG" Lima.dmg)"
if [[ -n "$remote_dmg_url" ]]; then
    remote_dmg_digest="$(gh api "$remote_dmg_url" --jq '.digest // empty')"
    local_dmg_digest="sha256:$(jq -er '.dmg.sha256' "$DIST/Lima-release.json")"
    if [[ "$remote_dmg_digest" == "$local_dmg_digest" ]]; then
        print 'DMG already exists remotely with the expected digest; skipping multipart upload.'
    else
        print -u2 'A draft already contains a different Lima.dmg; removing that draft asset before multipart reassembly.'
        gh release delete-asset "$TAG" Lima.dmg --yes
        remote_dmg_url=""
    fi
fi
if [[ -z "$remote_dmg_url" ]]; then
    PART_DIRECTORY="$DIST/.release-work/$TAG/parts"
    mkdir -p "$PART_DIRECTORY"
    parts=("$PART_DIRECTORY"/Lima.dmg.part-*(N))
    if (( ${#parts[@]} == 0 )); then
        split -b "$LIMA_RELEASE_DMG_PART_SIZE" -a "$LIMA_RELEASE_DMG_PART_SUFFIX_LENGTH" "$DIST/Lima.dmg" "$PART_DIRECTORY/Lima.dmg.part-"
        parts=("$PART_DIRECTORY"/Lima.dmg.part-*(N))
    fi
    part_count=${#parts[@]}
    (( part_count > 0 && part_count <= 64 )) || { print -u2 'DMG splitting produced an invalid part count.'; exit 1; }
    print "Uploading $part_count DMG parts."
    for part in "$PART_DIRECTORY"/Lima.dmg.part-*; do
        release_upload_if_needed "$TAG" "$part" "${part:t}" "$(shasum -a 256 "$part" | awk '{print $1}')"
    done

    before_id="$(gh run list --workflow assemble-signed-dmg.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
    gh workflow run assemble-signed-dmg.yml \
        -f release_tag="$TAG" \
        -f sha256="$(jq -er '.dmg.sha256' "$DIST/Lima-release.json")" \
        -f part_count="$part_count"
    run_id=""
    for _ in {1..30}; do
        for candidate in ${(f)"$(gh run list --workflow assemble-signed-dmg.yml --limit 20 --json databaseId --jq '.[].databaseId')"}; do
            if (( candidate > before_id )); then
                run_id="$candidate"
                break
            fi
        done
        [[ -n "$run_id" ]] && break
        sleep 2
    done
    [[ -n "$run_id" ]] || { print -u2 'Could not locate the DMG assembly workflow run.'; exit 1; }
    print "DMG assembly workflow: $run_id"
    metadata="$DIST/Lima-release.json"
    temporary_metadata="$(mktemp "${TMPDIR%/}/lima-release-metadata.XXXXXX")"
    jq --arg runId "$run_id" '.workflowRunId = ($runId | tonumber)' "$metadata" > "$temporary_metadata"
    mv -f "$temporary_metadata" "$metadata"
    if (( ! WAIT )); then
        release_upload_if_needed "$TAG" "$DIST/Lima-release.json" Lima-release.json "$(shasum -a 256 "$DIST/Lima-release.json" | awk '{print $1}')"
        print "Not waiting for workflow $run_id (--no-wait)."
        exit 0
    fi
    print "Waiting for DMG assembly workflow $run_id"
    gh run watch "$run_id" --exit-status
fi

# Upload the final metadata only after the DMG workflow ID, if any, has been
# recorded. Remote verification treats this file as the source of truth for
# the Sparkle archive URL, size, and digest.
release_upload_if_needed "$TAG" "$DIST/Lima-release.json" Lima-release.json "$(shasum -a 256 "$DIST/Lima-release.json" | awk '{print $1}')"
"$SCRIPT_DIRECTORY/release_verify.sh" --tag "$TAG" --remote-only
print "Draft staged and verified: $TAG"
print "Next: ./scripts/release_publish.sh --tag $TAG"
