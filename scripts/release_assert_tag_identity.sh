#!/bin/zsh
# Read-only exact tag/source identity gate for CI and release rehearsals.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"
TAG=""
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2;;
        -h|--help) print 'Usage: release_assert_tag_identity.sh --tag vX.Y.Z'; exit 0;;
        *) print -u2 "Unknown option: $1"; exit 2;;
    esac
done
[[ -n "$TAG" ]] || { print -u2 'A release tag is required.'; exit 2; }
release_assert_exact_tag_identity "$TAG"
