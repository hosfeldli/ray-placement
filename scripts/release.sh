#!/bin/zsh
# Lima release command dispatcher. See docs/RELEASING.md for the lifecycle.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"

release_tag_from_plist() {
    local version
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIRECTORY/../Packaging/Info.plist")"
    [[ "$version" == <->.<->.<-> ]] || { print -u2 "Invalid release version in Packaging/Info.plist: $version"; exit 1; }
    print -r -- "v$version"
}

release_deploy() {
    local tag="$1"
    local publish="$2"
    local confirmed="$3"

    if (( publish && ! confirmed )); then
        print -u2 "Publishing is irreversible. Use --publish --yes."
        exit 2
    fi

    "$SCRIPT_DIRECTORY/release_preflight.sh" --tag "$tag"
    # The successful preflight above is authoritative for this invocation.
    # Avoid re-running the same remote and signing checks before the local build.
    LIMA_RELEASE_SKIP_PREFLIGHT=1 "$SCRIPT_DIRECTORY/release_build.sh" --tag "$tag"
    "$SCRIPT_DIRECTORY/release_stage.sh" --tag "$tag"
    "$SCRIPT_DIRECTORY/release_verify.sh" --tag "$tag"

    if (( publish )); then
        "$SCRIPT_DIRECTORY/release_publish.sh" --tag "$tag" --yes
    else
        print "Draft is ready: $tag"
        print "Publish after review: ./scripts/release.sh publish --tag $tag --yes"
    fi
}

usage() {
    cat <<USAGE
Usage: release.sh <command> [options]

Commands:
  prepare    Change version metadata; use --bump patch|minor|major and optionally --commit --push.
  tag        Create and optionally push the immutable annotated release tag.
  preflight  Run read-only release gates.
  build      Run tests and build local signed artifacts.
  stage      Resume/create a draft and upload verified assets.
  verify     Verify local and remote artifacts.
  publish    Publish a verified draft; requires --yes for the irreversible action.
  deploy     Run preflight, build, stage, verify, and optionally publish an existing tag.
  ship       Prepare, tag, build, stage, verify, and optionally publish a new release.
  help       Show this help.

Examples:
  ./scripts/release.sh prepare --bump patch --commit --push
  ./scripts/release.sh tag --version 3.13.0 --push
  ./scripts/release.sh build --tag v3.12.6
  ./scripts/release.sh stage --tag v3.12.6
  ./scripts/release.sh publish --tag v3.12.6 --yes
  ./scripts/release.sh ship --bump patch
  ./scripts/release.sh ship --bump patch --publish --yes
USAGE
}
command="${1:-help}"
[[ $# -gt 0 ]] && shift || true
case "$command" in
    prepare) exec "$SCRIPT_DIRECTORY/release_prepare.sh" "$@";;
    tag) exec "$SCRIPT_DIRECTORY/release_tag.sh" "$@";;
    preflight) exec "$SCRIPT_DIRECTORY/release_preflight.sh" "$@";;
    build) exec "$SCRIPT_DIRECTORY/release_build.sh" "$@";;
    stage) exec "$SCRIPT_DIRECTORY/release_stage.sh" "$@";;
    verify) exec "$SCRIPT_DIRECTORY/release_verify.sh" "$@";;
    publish)
        confirmed=0
        publish_args=()
        while (( $# > 0 )); do
            case "$1" in
                --yes) confirmed=1; publish_args+=(--yes); shift;;
                --tag) publish_args+=(--tag "${2:?--tag requires a value}"); shift 2;;
                --dry-run) publish_args+=(--dry-run); shift;;
                -h|--help) "$SCRIPT_DIRECTORY/release_publish.sh" --help; exit 0;;
                *) print -u2 "Unknown publish option: $1"; usage >&2; exit 2;;
            esac
        done
        if (( ! confirmed )) && [[ ! " ${publish_args[*]} " == *" --dry-run "* ]]; then
            print -u2 "Publishing is irreversible. Re-run with --yes."
            exit 2
        fi
        exec "$SCRIPT_DIRECTORY/release_publish.sh" "${publish_args[@]}"
        ;;
    ship)
        version_args=()
        publish=0
        confirmed=0
        dry_run=0
        while (( $# > 0 )); do
            case "$1" in
                --bump) version_args+=(--bump "${2:?--bump requires patch, minor, or major}"); shift 2;;
                --version) version_args+=(--version "${2:?--version requires X.Y.Z}"); shift 2;;
                --publish) publish=1; shift;;
                --yes) confirmed=1; shift;;
                --dry-run) dry_run=1; shift;;
                -h|--help) usage; exit 0;;
                *) print -u2 "Unknown ship option: $1"; usage >&2; exit 2;;
            esac
        done
        (( ${#version_args[@]} == 2 )) || { print -u2 "ship requires exactly one of --bump or --version."; exit 2; }
        if (( dry_run )); then
            "$SCRIPT_DIRECTORY/release_prepare.sh" "${version_args[@]}" --dry-run
            print 'Dry run stops before committing, tagging, building, staging, or publishing.'
            exit 0
        fi
        if (( publish && ! confirmed )); then
            print -u2 "Publishing is irreversible. Use --publish --yes."
            exit 2
        fi
        "$SCRIPT_DIRECTORY/release_prepare.sh" "${version_args[@]}" --commit --push
        tag="$(release_tag_from_plist)"
        "$SCRIPT_DIRECTORY/release_tag.sh" --tag "$tag" --push
        release_deploy "$tag" "$publish" "$confirmed"
        ;;
    deploy)
        publish=0
        confirmed=0
        tag=""
        while (( $# > 0 )); do
            case "$1" in
                --publish) publish=1; shift;;
                --yes) confirmed=1; shift;;
                --tag) tag="${2:?--tag requires a value}"; shift 2;;
                -h|--help) usage; exit 0;;
                *) print -u2 "Unknown deploy option: $1"; usage >&2; exit 2;;
            esac
        done
        [[ -n "$tag" ]] || tag="$(release_tag_from_plist)"
        release_deploy "$tag" "$publish" "$confirmed"
        ;;
    help|-h|--help) usage;;
    *) print -u2 "Unknown release command: $command"; usage >&2; exit 2;;
esac
