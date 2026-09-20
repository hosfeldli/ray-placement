#!/bin/zsh
# Offline regression checks for the concise release dispatcher and first-draft path.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
DISPATCHER="${SCRIPT_DIRECTORY}/release.sh"

for script in release.sh release_preflight.sh release_stage.sh; do
    /bin/zsh -n "${SCRIPT_DIRECTORY}/$script"
done

help_output="$("$DISPATCHER" help)"
[[ "$help_output" == *"ship       Prepare, tag, build, stage, verify, and optionally publish a new release."* ]] || {
    print -u2 'Release dispatcher does not advertise the ship command.'
    exit 1
}

# This exercises new-release argument parsing and version calculation without
# creating a commit, tag, artifact, GitHub draft, or public release.
"$DISPATCHER" ship --bump patch --dry-run >/dev/null

if "$DISPATCHER" ship --bump patch --publish >/dev/null 2>&1; then
    print -u2 'ship accepted a public release request without --yes.'
    exit 1
fi

grep -Fq 'No GitHub release exists yet: stage will create a draft for $TAG.' "${SCRIPT_DIRECTORY}/release_preflight.sh" || {
    print -u2 'Preflight no longer accepts a newly pushed tag before its first draft.'
    exit 1
}
grep -Fq 'gh release create "$TAG" --draft --verify-tag' "${SCRIPT_DIRECTORY}/release_stage.sh" || {
    print -u2 'Staging no longer creates a first draft from the verified immutable tag.'
    exit 1
}

print 'Release dispatcher and first-draft regression tests passed.'
