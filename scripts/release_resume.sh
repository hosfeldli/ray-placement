#!/bin/zsh
# Resume an existing Lima draft without rebuilding or publishing it.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
TAG=""
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2;;
        -h|--help)
            cat <<USAGE
Usage: release_resume.sh --tag vX.Y.Z

Resumes multipart staging when needed, then verifies the draft. It never
rebuilds, publishes, commits, or pushes.
USAGE
            exit 0;;
        *) print -u2 "Unknown option: $1"; exit 2;;
    esac
done
[[ -n "$TAG" ]] || { print -u2 'A draft tag is required: --tag vX.Y.Z'; exit 2; }
"$SCRIPT_DIRECTORY/release_stage.sh" --tag "$TAG"
"$SCRIPT_DIRECTORY/release_verify.sh" --tag "$TAG"
