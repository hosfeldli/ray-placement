#!/bin/zsh
# Create and optionally push the immutable tag for a prepared Lima release.
# This is intentionally separate from version preparation and build/publish.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"

TAG=""
VERSION=""
PUSH=0

usage() {
    cat <<USAGE
Usage: release_tag.sh (--tag vX.Y.Z | --version X.Y.Z) [--push]

Creates an annotated immutable release tag only after verifying:
  * the source tree is clean;
  * the current branch is named and synchronized with its upstream;
  * the tag matches the plist version/build;
  * an existing local or remote tag cannot be repointed.

Options:
  --tag vX.Y.Z       Create the given release tag.
  --version X.Y.Z    Create vX.Y.Z.
  --push             Push the new tag to origin after creating it.
  -h, --help         Show this help.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires vX.Y.Z}"; shift 2;;
        --version) VERSION="${2:?--version requires X.Y.Z}"; shift 2;;
        --push) PUSH=1; shift;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done

[[ -n "$TAG" || -n "$VERSION" ]] || { print -u2 'Provide --tag or --version.'; exit 2; }
[[ -z "$TAG" || -z "$VERSION" ]] || { print -u2 'Use --tag or --version, not both.'; exit 2; }
if [[ -n "$VERSION" ]]; then
    lima_release_validate_version "$VERSION"
    TAG="v$VERSION"
fi
release_validate_tag "$TAG"

release_assert_clean_tree
release_assert_tag_matches_source "$TAG"

branch="$(git -C "$PROJECT_DIRECTORY" branch --show-current)"
[[ -n "$branch" ]] || { print -u2 'Cannot create a release tag from a detached HEAD.'; exit 1; }
upstream="$(git -C "$PROJECT_DIRECTORY" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
[[ -n "$upstream" ]] || { print -u2 "Branch $branch has no upstream; push the prepared commit first."; exit 1; }
counts=(${(z)$(git -C "$PROJECT_DIRECTORY" rev-list --left-right --count "$upstream...HEAD")})
[[ "${counts[1]}" == 0 && "${counts[2]}" == 0 ]] || {
    print -u2 "Local branch and $upstream are not identical; refusing to tag."; exit 1
}

head="$(git -C "$PROJECT_DIRECTORY" rev-parse HEAD)"
local_commit="$(git -C "$PROJECT_DIRECTORY" rev-list -n1 "$TAG" 2>/dev/null || true)"
if [[ -n "$local_commit" && "$local_commit" != "$head" ]]; then
    print -u2 "Local tag $TAG already points to $local_commit, not HEAD $head."; exit 1
fi

remote_lines="$(git -C "$PROJECT_DIRECTORY" ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}" 2>/dev/null || true)"
# An annotated tag reports both the tag object and its peeled commit. Prefer
# the peeled line; lightweight tags report only the direct commit line.
remote_commit="$(print -r -- "$remote_lines" | awk '$2 == "refs/tags/'"$TAG"'^{}" {print $1; exit}')"
[[ -n "$remote_commit" ]] || remote_commit="$(print -r -- "$remote_lines" | awk '$2 == "refs/tags/'"$TAG"'" {print $1; exit}')"
if [[ -n "$remote_commit" && "$remote_commit" != "$head" ]]; then
    print -u2 "Remote tag $TAG already exists at $remote_commit, not HEAD $head."; exit 1
fi

if [[ -z "$local_commit" ]]; then
    git -C "$PROJECT_DIRECTORY" tag -a "$TAG" "$head" -m "Lima $TAG"
    print "Created annotated tag $TAG at $head"
else
    print "Local tag $TAG already points to HEAD; leaving it unchanged."
fi

if (( PUSH )); then
    if [[ -n "$remote_commit" ]]; then
        print "Remote tag $TAG already points to HEAD; nothing to push."
    else
        git -C "$PROJECT_DIRECTORY" push origin "refs/tags/$TAG"
        print "Pushed immutable tag $TAG"
    fi
else
    print "Tag exists locally. Push it with: git push origin refs/tags/$TAG"
fi
