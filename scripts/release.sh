#!/bin/zsh
# Lima release command dispatcher. See docs/RELEASING.md for the lifecycle.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"

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
  deploy     Run preflight, build, stage, verify, and optionally publish.
  help       Show this help.

Examples:
  ./scripts/release.sh prepare --bump patch --commit --push
  ./scripts/release.sh tag --version 3.13.0 --push
  ./scripts/release.sh build --tag v3.12.6
  ./scripts/release.sh stage --tag v3.12.6
  ./scripts/release.sh publish --tag v3.12.6 --yes
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
    deploy)
        publish=0
        confirmed=0
        tag_args=()
        while (( $# > 0 )); do
            case "$1" in
                --publish) publish=1; shift;;
                --yes) confirmed=1; shift;;
                --tag) tag_args+=(--tag "${2:?--tag requires a value}"); shift 2;;
                -h|--help) usage; exit 0;;
                *) print -u2 "Unknown deploy option: $1"; usage >&2; exit 2;;
            esac
        done
        "$SCRIPT_DIRECTORY/release_preflight.sh" "${tag_args[@]}"
        "$SCRIPT_DIRECTORY/release_build.sh" "${tag_args[@]}"
        "$SCRIPT_DIRECTORY/release_stage.sh" "${tag_args[@]}"
        "$SCRIPT_DIRECTORY/release_verify.sh" "${tag_args[@]}"
        if (( publish )); then
            (( confirmed )) || { print -u2 "Publishing is irreversible. Use --publish --yes."; exit 2; }
            "$SCRIPT_DIRECTORY/release_publish.sh" "${tag_args[@]}" --yes
        else
            print 'Draft is ready. Run release.sh publish with the same tag after review.'
        fi
        ;;
    help|-h|--help) usage;;
    *) print -u2 "Unknown release command: $command"; usage >&2; exit 2;;
esac
