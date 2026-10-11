#!/bin/zsh
# Offline regression checks for the standalone hosted-deploy wrapper.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
DEPLOY="${SCRIPT_DIRECTORY}/deploy-release.sh"

for script in deploy-release.sh release_prepare.sh release_tag.sh; do
    /bin/zsh -n "${SCRIPT_DIRECTORY}/$script"
done

help_output="$("$DEPLOY" --help)"
[[ "$help_output" == *'Usage: deploy-release.sh --bump patch|minor|major --publish'* ]] || {
    print -u2 'Deployment wrapper help does not show the one-command public-release usage.'
    exit 1
}
[[ "$help_output" == *'never moves an existing tag'* ]] || {
    print -u2 'Deployment wrapper help must state its immutable-tag guarantee.'
    exit 1
}

if "$DEPLOY" --bump patch >/dev/null 2>&1; then
    print -u2 'Deployment wrapper accepted a public deployment without --publish.'
    exit 1
fi
if "$DEPLOY" --bump path --publish --dry-run >/dev/null 2>&1; then
    print -u2 'Deployment wrapper accepted an unsupported bump value.'
    exit 1
fi
if "$DEPLOY" --publish --dry-run >/dev/null 2>&1; then
    print -u2 'Deployment wrapper accepted a missing bump value.'
    exit 1
fi

before_status="$(git -C "$PROJECT_DIRECTORY" status --porcelain)"
dry_run_output="$("$DEPLOY" --bump patch --publish --dry-run)"
after_status="$(git -C "$PROJECT_DIRECTORY" status --porcelain)"
[[ "$before_status" == "$after_status" ]] || {
    print -u2 'Deployment dry-run changed the repository worktree.'
    exit 1
}
[[ "$dry_run_output" == *'Next version:'* ]] || {
    print -u2 'Deployment dry-run did not report the computed version.'
    exit 1
}
[[ "$dry_run_output" == *'no files, commits, tags, remotes, or workflows changed'* ]] || {
    print -u2 'Deployment dry-run did not state that it is side-effect free.'
    exit 1
}

print 'Standalone hosted-deploy wrapper tests passed.'
