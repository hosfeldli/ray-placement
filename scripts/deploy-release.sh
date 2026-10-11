#!/bin/zsh
# Prepare a new Lima patch/minor/major release, wait for its exact CI run, then
# dispatch the hosted release workflow and exit without monitoring publication.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
REPO="hosfeldli/ray-placement"
CI_WORKFLOW="ci.yml"
RELEASE_WORKFLOW="release-update.yml"
BUMP=""
PUBLISH=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: deploy-release.sh --bump patch|minor|major --publish [--dry-run]

Prepare and push one new Lima version, wait for CI on that exact commit,
create its immutable tag, dispatch the hosted public-release workflow, then
exit with the workflow URL. The hosted build continues in GitHub after exit.

Options:
  --bump patch|minor|major  Choose the next semantic version.
  --publish                 Explicitly request public publication.
  --dry-run                 Show the next version and planned steps only.
  -h, --help                 Show this help.

The wrapper requires a clean, synchronized main branch and GitHub CLI access.
It never moves an existing tag and never bypasses the protected release
environment. Configure GitHub Actions email notifications for all workflow
runs to receive a completion email.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --bump)
            [[ $# -ge 2 ]] || { print -u2 '--bump requires patch, minor, or major.'; exit 2; }
            BUMP="$2"
            shift 2
            ;;
        --publish) PUBLISH=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done

case "$BUMP" in
    patch|minor|major) ;;
    *) print -u2 'Choose exactly one --bump patch, minor, or major.'; exit 2;;
esac
if (( ! PUBLISH && ! DRY_RUN )); then
    print -u2 'A public deployment requires the explicit --publish flag.'
    exit 2
fi

source "$SCRIPT_DIRECTORY/release_config.sh"
PLIST="$PROJECT_DIRECTORY/Packaging/Info.plist"
current_version="$(lima_release_version_from_plist "$PLIST")"
lima_release_validate_version "$current_version"

# Reuse the canonical release-preparation version logic for preview and execution.
preview="$("$SCRIPT_DIRECTORY/release_prepare.sh" --bump "$BUMP" --dry-run)"
version="$(print -r -- "$preview" | /usr/bin/awk '/^Next version:/ { print $3; exit }')"
[[ -n "$version" ]] || { print -u2 'Could not determine the next version from release_prepare.sh.'; exit 1; }
lima_release_validate_version "$version"
lima_release_build_number "$version" >/dev/null
tag="v$version"

print "Current version: $current_version"
print "Next version:    $version"
if (( DRY_RUN )); then
    print "Would commit and push the version metadata, wait for CI on that commit, create immutable tag $tag, and dispatch the hosted public-release workflow."
    print 'Dry run: no files, commits, tags, remotes, or workflows changed.'
    exit 0
fi

command -v git >/dev/null || { print -u2 'git is required.'; exit 1; }
command -v gh >/dev/null || { print -u2 'GitHub CLI (gh) is required.'; exit 1; }
command -v jq >/dev/null || { print -u2 'jq is required.'; exit 1; }
[[ "$(git -C "$PROJECT_DIRECTORY" branch --show-current)" == main ]] || {
    print -u2 'Deployments must start from the main branch.'
    exit 1
}
[[ -z "$(git -C "$PROJECT_DIRECTORY" status --porcelain)" ]] || {
    print -u2 'The source working tree must be clean before deployment.'
    git -C "$PROJECT_DIRECTORY" status --short >&2
    exit 1
}

gh auth status --hostname github.com >/dev/null
actual_repo="$(gh repo view "$REPO" --json nameWithOwner --jq '.nameWithOwner')"
[[ "$actual_repo" == "$REPO" ]] || {
    print -u2 "GitHub resolved $actual_repo, expected $REPO."
    exit 1
}

git -C "$PROJECT_DIRECTORY" fetch origin main --tags
upstream="$(git -C "$PROJECT_DIRECTORY" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
[[ "$upstream" == origin/main ]] || {
    print -u2 "The main branch must track origin/main (found: ${upstream:-none})."
    exit 1
}
counts=(${(z)$(git -C "$PROJECT_DIRECTORY" rev-list --left-right --count origin/main...HEAD)})
[[ "${counts[1]}" == 0 && "${counts[2]}" == 0 ]] || {
    print -u2 'Local main and origin/main must be identical before deployment.'
    exit 1
}
[[ -z "$(git -C "$PROJECT_DIRECTORY" tag --list "$tag")" ]] || {
    print -u2 "Local immutable tag $tag already exists; refusing to reuse it."
    exit 1
}
[[ -z "$(git -C "$PROJECT_DIRECTORY" ls-remote --refs origin "refs/tags/$tag")" ]] || {
    print -u2 "Remote immutable tag $tag already exists; refusing to reuse it."
    exit 1
}

print "Preparing and pushing Lima $version..."
"$SCRIPT_DIRECTORY/release_prepare.sh" --bump "$BUMP" --commit --push
commit="$(git -C "$PROJECT_DIRECTORY" rev-parse HEAD)"
[[ "$(lima_release_version_from_plist "$PLIST")" == "$version" ]] || {
    print -u2 'Version metadata changed unexpectedly after preparation.'
    exit 1
}

print "Finding CI run for $commit..."
ci_run_id=""
for attempt in {1..30}; do
    ci_runs="$(gh run list --repo "$REPO" --workflow "$CI_WORKFLOW" --event push --branch main --commit "$commit" --limit 10 --json databaseId,headSha 2>/dev/null || true)"
    ci_run_id="$(print -r -- "$ci_runs" | jq -r --arg sha "$commit" '[.[] | select(.headSha == $sha)][0].databaseId // empty' 2>/dev/null || true)"
    [[ -n "$ci_run_id" ]] && break
    sleep 2
done
[[ -n "$ci_run_id" ]] || {
    print -u2 "Version commit $commit was pushed, but its CI run did not appear within 60 seconds."
    print -u2 "Inspect: https://github.com/$REPO/actions/workflows/$CI_WORKFLOW"
    exit 1
}

print "Waiting for CI run $ci_run_id on $commit..."
gh run watch "$ci_run_id" --repo "$REPO" --exit-status
ci_result="$(gh run view "$ci_run_id" --repo "$REPO" --json headSha,status,conclusion)"
print -r -- "$ci_result" | jq -e --arg sha "$commit" '.headSha == $sha and .status == "completed" and .conclusion == "success"' >/dev/null || {
    print -u2 "CI did not pass for $commit; no release tag or deployment was created."
    exit 1
}

print "Creating immutable tag $tag..."
"$SCRIPT_DIRECTORY/release_tag.sh" --version "$version" --push

print "Dispatching the hosted public release for $tag..."
gh workflow run "$RELEASE_WORKFLOW" --repo "$REPO" --ref main -f "release_tag=$tag" -f publish=true

# Resolve the dispatched run ID for a useful handoff, but do not monitor the
# hosted build, environment approval, staging, or publication from this command.
release_run_id=""
for attempt in {1..30}; do
    release_runs="$(gh run list --repo "$REPO" --workflow "$RELEASE_WORKFLOW" --event workflow_dispatch --branch main --commit "$commit" --limit 10 --json databaseId,headSha 2>/dev/null || true)"
    release_run_id="$(print -r -- "$release_runs" | jq -r --arg sha "$commit" '[.[] | select(.headSha == $sha)][0].databaseId // empty' 2>/dev/null || true)"
    [[ -n "$release_run_id" ]] && break
    sleep 2
done

if [[ -n "$release_run_id" ]]; then
    release_url="$(gh run view "$release_run_id" --repo "$REPO" --json url --jq '.url')"
    print "Hosted release started: $release_url"
else
    print 'GitHub accepted the dispatch, but the run ID is not visible yet.'
    print "Do not dispatch again; inspect: https://github.com/$REPO/actions/workflows/$RELEASE_WORKFLOW"
fi
print 'This command is finished; GitHub continues the hosted build and publication.'
print 'If required, approve the protected release environment using GitHub’s deployment-review flow.'
print 'For a completion email, enable GitHub Settings → Notifications → Actions → all workflow runs and select a verified notification address: https://github.com/settings/notifications.'
print 'The release is not confirmed public until the GitHub run succeeds and the release is no longer a draft.'
