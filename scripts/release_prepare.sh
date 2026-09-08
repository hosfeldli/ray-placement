#!/bin/zsh
# Prepare a Lima version without building, uploading, or publishing anything.
# This is the only release command allowed to change version metadata.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
PLIST="$PROJECT_DIRECTORY/Packaging/Info.plist"
README="$PROJECT_DIRECTORY/README.md"
COMMIT=0
PUSH=0
DRY_RUN=0
ALLOW_DIRTY=0
REQUESTED_VERSION=""
BUMP=""

usage() {
    cat <<USAGE
Usage: release_prepare.sh [options]

Choose exactly one version operation:
  --version X.Y.Z    Set an explicit semantic version.
  --bump patch       Increment the patch component ("path" is accepted as an alias).
  --bump minor       Increment the minor component and reset patch to zero.
  --bump major       Increment the major component and reset minor/patch to zero.

Options:
  --commit            Commit the metadata change.
  --push              Push the commit to the current branch (implies --commit).
  --dry-run           Show the planned change without modifying files.
  --no-commit         Explicitly leave the change uncommitted (the default).
  --no-push           Explicitly do not push (the default).
  --allow-dirty       Allow unrelated pre-existing source changes; use sparingly.
  --rehearsal         Permit the version change while preserving unrelated refactor changes.
  -h, --help          Show this help.

Examples:
  ./scripts/release_prepare.sh --bump patch --commit --push
  ./scripts/release_prepare.sh --version 3.13.0 --commit
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --version) REQUESTED_VERSION="${2:?--version requires X.Y.Z}"; shift 2;;
        --bump) BUMP="${2:?--bump requires major, minor, or patch}"; shift 2;;
        --commit) COMMIT=1; shift;;
        --push) PUSH=1; COMMIT=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --no-commit) COMMIT=0; shift;;
        --no-push) PUSH=0; shift;;
        --allow-dirty|--rehearsal) ALLOW_DIRTY=1; shift;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done

[[ -n "$REQUESTED_VERSION" || -n "$BUMP" ]] || { print -u2 'Choose --version or --bump.'; exit 2; }
[[ -z "$REQUESTED_VERSION" || -z "$BUMP" ]] || { print -u2 'Use --version or --bump, not both.'; exit 2; }

source "$SCRIPT_DIRECTORY/release_config.sh"
current_version="$(lima_release_version_from_plist "$PLIST")"
lima_release_validate_version "$current_version"

if [[ -n "$BUMP" ]]; then
    case "$BUMP" in
        path) BUMP=patch;;
        major|minor|patch) ;;
        *) print -u2 "Invalid bump: $BUMP"; exit 2;;
    esac
    current_parts=(${(s/./)current_version})
    case "$BUMP" in
        major) REQUESTED_VERSION="$((current_parts[1] + 1)).0.0";;
        minor) REQUESTED_VERSION="${current_parts[1]}.$((current_parts[2] + 1)).0";;
        patch) REQUESTED_VERSION="${current_parts[1]}.${current_parts[2]}.$((current_parts[3] + 1))";;
    esac
fi
lima_release_validate_version "$REQUESTED_VERSION"
[[ "$REQUESTED_VERSION" != "$current_version" ]] || { print -u2 "Version is already $REQUESTED_VERSION."; exit 1; }
new_build="$(lima_release_build_number "$REQUESTED_VERSION")"

print "Current version: $current_version ($(lima_release_build_number "$current_version"))"
print "Next version:    $REQUESTED_VERSION ($new_build)"

if (( DRY_RUN )); then
    print 'Dry run: no files, commits, or remotes changed.'
    exit 0
fi

# Preparation intentionally requires a clean tree. Build artifacts under ignored
# directories do not count as source changes.
if [[ -n "$(git -C "$PROJECT_DIRECTORY" status --porcelain)" ]]; then
    if (( ! ALLOW_DIRTY )); then
        print -u2 'The source working tree must be clean before preparing a release.'
        git -C "$PROJECT_DIRECTORY" status --short >&2
        exit 1
    fi
    print -u2 'Warning: proceeding with pre-existing source changes because --allow-dirty was supplied.'
fi

if ! OLD_VERSION="$current_version" /usr/bin/perl -0ne 'exit((/^# Lima \Q$ENV{OLD_VERSION}\E\b/m && /The `\Q$ENV{OLD_VERSION}\E` package/)?0:1)' "$README"; then
    print -u2 "README release references for $current_version were not found; refusing to edit an unexpected document."
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $REQUESTED_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $new_build" "$PLIST"

# Keep the human-facing distribution note synchronized without making README the
# source of truth. Fail rather than silently editing an unexpected document.
OLD_VERSION="$current_version" NEW_VERSION="$REQUESTED_VERSION" /usr/bin/perl -0pi -e 's/\A# Lima \Q$ENV{OLD_VERSION}\E\b/# Lima $ENV{NEW_VERSION}/ or die "README heading does not match\n"; s/The `\Q$ENV{OLD_VERSION}\E` package/The `$ENV{NEW_VERSION}` package/ or die "README distribution note does not match\n";' "$README"

"$SCRIPT_DIRECTORY/check_release_consistency.sh"
git -C "$PROJECT_DIRECTORY" diff --check

git -C "$PROJECT_DIRECTORY" diff -- Packaging/Info.plist README.md

if (( COMMIT )); then
    git -C "$PROJECT_DIRECTORY" add Packaging/Info.plist README.md
    git -C "$PROJECT_DIRECTORY" commit -m "Bump Lima version to $REQUESTED_VERSION"
fi
if (( PUSH )); then
    branch="$(git -C "$PROJECT_DIRECTORY" branch --show-current)"
    [[ -n "$branch" ]] || { print -u2 'Cannot push from a detached HEAD.'; exit 1; }
    git -C "$PROJECT_DIRECTORY" push origin "$branch"
fi
if (( ! COMMIT )); then
    print 'Prepared files but did not commit them. Review and commit before running release_preflight.sh.'
fi
