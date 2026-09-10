#!/bin/zsh
# Read-only release gate. It never changes source files, Git refs, keychains,
# releases, or uploaded assets.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"
TAG=""

usage() {
    cat <<USAGE
Usage: release_preflight.sh [--tag vX.Y.Z]

Checks:
  * clean, pushed Git worktree
  * plist version/build/tag consistency
  * Lima's pinned self-signed signing policy
  * local signing keychain and certificate fingerprint
  * required tools, GitHub authentication, and disk space
  * existing release/tag state without modifying it
USAGE
}
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done

[[ -n "$TAG" ]] || TAG="$(release_default_tag)"
for cmd in git gh jq python3 swift codesign security shasum rsync hdiutil split plutil openssl; do release_require_cmd "$cmd"; done
[[ -f "$PROJECT_DIRECTORY/Package.swift" ]] || { print -u2 "Not a Lima project: $PROJECT_DIRECTORY"; exit 1; }
release_assert_clean_tree
"$SCRIPT_DIRECTORY/check_release_consistency.sh"
release_assert_tag_matches_source "$TAG"
release_assert_exact_tag_identity "$TAG"

branch="$(git -C "$PROJECT_DIRECTORY" branch --show-current)"
upstream="$(git -C "$PROJECT_DIRECTORY" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [[ -n "$upstream" ]]; then
    counts=(${(z)$(git -C "$PROJECT_DIRECTORY" rev-list --left-right --count "$upstream...HEAD")})
    [[ "${counts[1]}" == 0 && "${counts[2]}" == 0 ]] || { print -u2 "Local branch and $upstream are not identical; refusing release."; exit 1; }
elif [[ "${GITHUB_ACTIONS:-0}" == true || "${CI:-0}" == true ]]; then
    # actions/checkout commonly leaves a detached HEAD. The release workflow
    # explicitly checks out the requested immutable tag, so never infer the
    # expected ref from GITHUB_REF_NAME: that value describes the workflow
    # dispatch event and may still point at main or another branch.
    remote_ref="${LIMA_RELEASE_EXPECTED_REF:-refs/tags/$TAG}"
    [[ "$remote_ref" == refs/tags/* || "$remote_ref" == refs/remotes/origin/* ]] || {
        print -u2 "Unsupported CI expected ref: $remote_ref"; exit 1;
    }
    # Annotated tags resolve to a tag object with rev-parse; compare the
    # checkout against the peeled commit instead.
    remote_commit="$(git -C "$PROJECT_DIRECTORY" rev-list -n1 "$remote_ref" 2>/dev/null || true)"
    [[ -n "$remote_commit" && "$remote_commit" == "$(git -C "$PROJECT_DIRECTORY" rev-parse HEAD)" ]] || {
        print -u2 "CI HEAD is not the pushed commit for $remote_ref; refusing release."; exit 1
    }
    branch="${GITHUB_REF_NAME:-detached-ci}"
    upstream="$remote_ref"
else
    print -u2 "Release must run from a named branch with an upstream."
    exit 1
fi

lima_release_validate_signing_policy
lima_release_export_packaging_policy
if [[ "$LIMA_RELEASE_SIGNING_MODE" == self-signed-local ]]; then
    [[ -f "$LIMA_RELEASE_LOCAL_SIGNING_KEYCHAIN" && -f "$LIMA_RELEASE_LOCAL_SIGNING_PASSWORD" ]] || {
        print -u2 "Self-signed keychain/password are missing under $LIMA_RELEASE_LOCAL_SIGNING_DIRECTORY."; exit 1;
    }
    identity_hash="$(security find-identity -v -p codesigning "$LIMA_RELEASE_LOCAL_SIGNING_KEYCHAIN" | awk -v identity="$LIMA_RELEASE_SIGNING_IDENTITY" 'index($0, "\"" identity "\"") {print $2; exit}')"
    [[ -n "$identity_hash" ]] || { print -u2 'The pinned local signing identity is not valid in its keychain.'; exit 1; }
    actual_certificate="$(security find-certificate -a -c "$LIMA_RELEASE_SIGNING_IDENTITY" -p "$LIMA_RELEASE_LOCAL_SIGNING_KEYCHAIN" | openssl x509 -outform der 2>/dev/null | shasum -a 256 | awk '{print tolower($1)}')"
    [[ "$actual_certificate" == "${LIMA_RELEASE_CERTIFICATE_SHA256:l}" ]] || {
        print -u2 "Signing certificate mismatch: configured ${LIMA_RELEASE_CERTIFICATE_SHA256:l}, found $actual_certificate."; exit 1;
    }
fi

gh auth status >/dev/null
release_exists=0
release_is_draft=0
if gh release view "$TAG" >/dev/null 2>&1; then
    release_exists=1
    release_state="$(gh release view "$TAG" --json isDraft --jq .isDraft)"
    [[ "$release_state" == true ]] || { print -u2 "$TAG is already published; choose a new version."; exit 1; }
    release_is_draft=1
    print "Existing draft found: $TAG (resume is safe)."
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && (( ! release_is_draft )); then
    print -u2 "Remote tag $TAG already exists without a resumable draft release; refusing to reuse it."; exit 1
fi

available_kb="$(df -Pk "$PROJECT_DIRECTORY" | awk 'NR==2 {print $4}')"
(( available_kb >= LIMA_RELEASE_MINIMUM_FREE_KB )) || {
    print -u2 "Insufficient disk space: need $((LIMA_RELEASE_MINIMUM_FREE_KB / 1024 / 1024)) GB free."; exit 1;
}

print "Preflight passed for $TAG"
print "  source:  $(git -C "$PROJECT_DIRECTORY" rev-parse --short HEAD)"
print "  branch:  $branch (in sync with $upstream)"
print "  signing: $LIMA_RELEASE_SIGNING_MODE / $LIMA_RELEASE_SIGNING_IDENTITY"
print "  disk:    $((available_kb / 1024 / 1024)) GB available"
