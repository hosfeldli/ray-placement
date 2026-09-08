#!/bin/zsh
# Publish a verified draft release. This is the only script that changes a
# GitHub release from draft to public.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"
TAG=""
DRY_RUN=0
CONFIRMED=0

usage() {
    cat <<USAGE
Usage: release_publish.sh [--tag vX.Y.Z] [--yes] [--dry-run]

Requires a staged draft and matching local/remote digests. Publishing also
requires --yes. Dry-run performs all checks but does not publish.
USAGE
}
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2;;
        --yes) CONFIRMED=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done
[[ -n "$TAG" ]] || TAG="$(release_default_tag)"
if (( ! CONFIRMED && ! DRY_RUN )); then
    print -u2 'Publishing is irreversible. Re-run with --yes.'
    exit 2
fi
release_assert_clean_tree
release_assert_draft "$TAG"
"$SCRIPT_DIRECTORY/release_verify.sh" --tag "$TAG"
if (( DRY_RUN )); then
    print "Dry run: $TAG is verified and ready to publish."
    exit 0
fi
gh release edit "$TAG" --draft=false
# Confirm GitHub has promoted the exact release we verified.
[[ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" == false ]] || { print -u2 "GitHub did not publish $TAG."; exit 1; }
print "Published: https://github.com/hosfeldli/ray-placement/releases/tag/$TAG"
