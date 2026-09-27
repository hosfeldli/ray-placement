#!/bin/zsh
# Restore a previously verified release archive without rebuilding it. The
# archive remains private; restored bytes must still satisfy Lima's local
# metadata, checksum, tag, and feed validation before staging can resume.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"

TAG=""
DESTINATION="$PROJECT_DIRECTORY/dist"
REPLACE=0
usage() {
    print 'Usage: restore_release_from_gcs.sh --tag vX.Y.Z [--replace]'
}
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
        --replace) REPLACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done
[[ -n "$TAG" ]] || { usage >&2; exit 2; }
ARCHIVE_BUCKET="${LIMA_RELEASE_ARCHIVE_BUCKET:-}"
[[ "$ARCHIVE_BUCKET" =~ '^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$' ]] || {
    print -u2 'LIMA_RELEASE_ARCHIVE_BUCKET must name a private GCS bucket.'
    exit 1
}
command -v gcloud >/dev/null 2>&1 || { print -u2 'gcloud is required to restore release artifacts.'; exit 1; }

typeset -a artifacts
artifacts=(
    Lima-Update.zip Lima-Update.sha256
    Lima-Sparkle.zip Lima-Sparkle.sha256
    Lima.dmg Lima.dmg.sha256
    Lima-release.json latest.json appcast.xml
)

if (( ! REPLACE )); then
    for artifact in "${artifacts[@]}"; do
        [[ ! -e "$DESTINATION/$artifact" ]] || {
            print -u2 "Destination already contains $artifact; use an empty destination or --replace."
            exit 1
        }
    done
fi
mkdir -p "$DESTINATION"

temporary_directory="$(mktemp -d "${TMPDIR%/}/lima-restore.XXXXXX")"
cleanup() { rm -rf -- "$temporary_directory"; }
trap cleanup EXIT

version="${TAG#v}"
metadata_remote="gs://$ARCHIVE_BUCKET/releases/$version/Lima-release.json"
gcloud storage cp "$metadata_remote" "$temporary_directory/Lima-release.json" >/dev/null
[[ "$(jq -er '.schemaVersion' "$temporary_directory/Lima-release.json")" == 1 ]] || {
    print -u2 'Archived metadata schema is unsupported.'
    exit 1
}
[[ "$(jq -er '.tag' "$temporary_directory/Lima-release.json")" == "$TAG" ]] || {
    print -u2 'Archived metadata tag does not match the requested tag.'
    exit 1
}
[[ "$(jq -er '.version' "$temporary_directory/Lima-release.json")" == "$version" ]] || {
    print -u2 'Archived metadata version does not match the requested tag.'
    exit 1
}
archived_commit="$(jq -er '.commit' "$temporary_directory/Lima-release.json")"
[[ "$archived_commit" == "$(git -C "$PROJECT_DIRECTORY" rev-parse HEAD)" ]] || {
    print -u2 'Checked-out source does not match the archived release commit.'
    exit 1
}
release_assert_exact_tag_identity "$TAG"

for artifact in "${artifacts[@]}"; do
    gcloud storage cp "gs://$ARCHIVE_BUCKET/releases/$version/$artifact" "$temporary_directory/$artifact" >/dev/null
done

(
    cd "$temporary_directory"
    shasum -a 256 --check Lima-Update.sha256
    shasum -a 256 --check Lima-Sparkle.sha256
    shasum -a 256 --check Lima.dmg.sha256
)
[[ "$(jq -er '.update.sha256' "$temporary_directory/Lima-release.json")" == "$(shasum -a 256 "$temporary_directory/Lima-Update.zip" | awk '{print $1}')" ]]
[[ "$(jq -er '.sparkleUpdate.sha256' "$temporary_directory/Lima-release.json")" == "$(shasum -a 256 "$temporary_directory/Lima-Sparkle.zip" | awk '{print $1}')" ]]
[[ "$(jq -er '.dmg.sha256' "$temporary_directory/Lima-release.json")" == "$(shasum -a 256 "$temporary_directory/Lima.dmg" | awk '{print $1}')" ]]

if (( REPLACE )); then
    for artifact in "${artifacts[@]}"; do
        rm -f -- "$DESTINATION/$artifact"
    done
fi
for artifact in "${artifacts[@]}"; do
    mv "$temporary_directory/$artifact" "$DESTINATION/$artifact"
done
release_assert_distribution_metadata "$TAG"
print "Restored and verified archived release artifacts for $TAG."
