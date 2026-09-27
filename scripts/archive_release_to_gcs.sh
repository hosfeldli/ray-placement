#!/bin/zsh
# Archive verified, private release inputs before GitHub draft staging. This
# script deliberately uploads the existing dist/ contract; it does not build,
# sign, create tags, or publish a release.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"

TAG=""
usage() {
    print 'Usage: archive_release_to_gcs.sh --tag vX.Y.Z'
}
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
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
command -v gcloud >/dev/null 2>&1 || { print -u2 'gcloud is required to archive release artifacts.'; exit 1; }

DIST="$PROJECT_DIRECTORY/dist"
METADATA="$DIST/Lima-release.json"
release_assert_distribution_metadata "$TAG"
commit="$(jq -er '.commit' "$METADATA")"
version="$(jq -er '.version' "$METADATA")"
[[ "$version" == "${TAG#v}" ]] || { print -u2 'Release metadata version/tag mismatch.'; exit 1; }

typeset -a artifacts
artifacts=(
    Lima-Update.zip Lima-Update.sha256
    Lima-Sparkle.zip Lima-Sparkle.sha256
    Lima.dmg Lima.dmg.sha256
    Lima-release.json latest.json appcast.xml
)
for artifact in "${artifacts[@]}"; do
    [[ -f "$DIST/$artifact" && ! -L "$DIST/$artifact" ]] || {
        print -u2 "Missing or symbolic release artifact: $artifact"
        exit 1
    }
done

temporary_directory="$(mktemp -d "${TMPDIR%/}/lima-archive-verify.XXXXXX")"
cleanup() { rm -rf -- "$temporary_directory"; }
trap cleanup EXIT

archive_prefix() {
    local prefix="$1"
    local artifact destination retrieved
    for artifact in "${artifacts[@]}"; do
        destination="${prefix%/}/$artifact"
        if gcloud storage ls "$destination" >/dev/null 2>&1; then
            retrieved="$temporary_directory/${artifact:t}"
            rm -f "$retrieved"
            gcloud storage cp "$destination" "$retrieved" >/dev/null
            cmp -s "$DIST/$artifact" "$retrieved" || {
                print -u2 "Archive collision for $destination; existing bytes differ."
                exit 1
            }
        else
            gcloud storage cp --if-generation-match=0 "$DIST/$artifact" "$destination" >/dev/null
        fi
    done

    retrieved="$temporary_directory/Lima-release.json"
    rm -f "$retrieved"
    gcloud storage cp "${prefix%/}/Lima-release.json" "$retrieved" >/dev/null
    cmp -s "$METADATA" "$retrieved" || {
        print -u2 "Archived release metadata does not match verified local metadata."
        exit 1
    }
}

archive_prefix "gs://$ARCHIVE_BUCKET/builds/$commit"
archive_prefix "gs://$ARCHIVE_BUCKET/releases/$version"
print "Archived verified release artifacts for $TAG to private GCS storage."
