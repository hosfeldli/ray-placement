#!/bin/zsh
# Remove only the disposable signing files and keychain created by
# ci_prepare_signing.sh. GitHub-hosted runners are destroyed after the job;
# this script is safe to run after a failed build as well.
set -euo pipefail

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || {
    print -u2 "ci_cleanup_signing.sh is restricted to GitHub Actions runners."
    exit 1
}

SIGNING_DIRECTORY="${LIMA_RELEASE_SIGNING_DIRECTORY:-${RAYPLACEMENT_SIGNING_DIRECTORY:-}}"
[[ -n "$SIGNING_DIRECTORY" ]] || exit 0
case "$SIGNING_DIRECTORY" in
    "${RUNNER_TEMP%/}"/*) ;;
    *) print -u2 "Refusing to remove a signing directory outside RUNNER_TEMP."; exit 1 ;;
esac

KEYCHAIN_PATH="${LIMA_RELEASE_SIGNING_KEYCHAIN:-${RAYPLACEMENT_SIGNING_KEYCHAIN:-$SIGNING_DIRECTORY/RayPlacementSigning.keychain-db}}"
security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
rm -rf -- "$SIGNING_DIRECTORY"
print "Removed ephemeral Lima signing material."
