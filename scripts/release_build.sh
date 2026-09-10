#!/bin/zsh
# Build and verify local release artifacts. No GitHub release is created.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
LIMA_PROJECT_DIRECTORY="$PROJECT_DIRECTORY"
source "$SCRIPT_DIRECTORY/release_common.sh"
TAG=""
REUSE=0

usage() {
    cat <<USAGE
Usage: release_build.sh [--tag vX.Y.Z] [--reuse]

Runs the complete local test suite, creates the model-free update archive and
full DMG, verifies both artifacts, and writes dist/Lima-release.json.
This command never commits, pushes, creates a GitHub release, or publishes.
Use --reuse to accept a complete, checksum-matching dist/ build without rebuilding it.
USAGE
}
while (( $# > 0 )); do
    case "$1" in
        --tag) TAG="${2:?--tag requires a value}"; shift 2;;
        --reuse) REUSE=1; shift;;
        -h|--help) usage; exit 0;;
        *) print -u2 "Unknown option: $1"; usage >&2; exit 2;;
    esac
done
[[ -n "$TAG" ]] || TAG="$(release_default_tag)"
if [[ "${LIMA_RELEASE_SKIP_PREFLIGHT:-0}" == 1 ]]; then
    print 'Skipping preflight because LIMA_RELEASE_SKIP_PREFLIGHT=1 was explicitly supplied.'
else
    "$SCRIPT_DIRECTORY/release_preflight.sh" --tag "$TAG"
fi
lima_release_export_packaging_policy
release_assert_exact_tag_identity "$TAG"

DIST="$PROJECT_DIRECTORY/dist"

reuse_complete=1
for artifact in Lima-Update.zip Lima-Update.sha256 Lima-Sparkle.zip Lima-Sparkle.sha256 Lima.dmg Lima.dmg.sha256 Lima-release.json latest.json appcast.xml; do
    [[ -f "$DIST/$artifact" ]] || reuse_complete=0
done
if (( reuse_complete )); then
    [[ "$(jq -er '.tag' "$DIST/Lima-release.json" 2>/dev/null || true)" == "$TAG" ]] || reuse_complete=0
    [[ "$(jq -er '.version' "$DIST/Lima-release.json" 2>/dev/null || true)" == "$(release_version)" ]] || reuse_complete=0
    [[ "$(jq -er '.build' "$DIST/Lima-release.json" 2>/dev/null || true)" == "$(release_build_number)" ]] || reuse_complete=0
    [[ "$(jq -er '.commit' "$DIST/Lima-release.json" 2>/dev/null || true)" == "$(git -C "$PROJECT_DIRECTORY" rev-parse HEAD)" ]] || reuse_complete=0
    (cd "$DIST" && shasum -a 256 --check Lima-Update.sha256 && shasum -a 256 --check Lima-Sparkle.sha256 && shasum -a 256 --check Lima.dmg.sha256) >/dev/null 2>&1 || reuse_complete=0
fi
if (( REUSE && reuse_complete )); then
    print "Reusing complete checksum-matching build for $TAG."
    RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$SCRIPT_DIRECTORY/verify_liamflow_app.sh" "$PROJECT_DIRECTORY/build/Lima.app"
    RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$SCRIPT_DIRECTORY/verify_liamflow_dmg.sh" "$DIST/Lima.dmg"
    release_assert_distribution_metadata "$TAG"
    print "Reuse verification passed."
    exit 0
fi
if (( REUSE && ! reuse_complete )); then
    print -- "--reuse requested, but the existing build is incomplete or mismatched; rebuilding."
fi
mkdir -p "$DIST"
rm -f "$DIST/Lima-Update.zip" "$DIST/Lima-Update.sha256" "$DIST/Lima-Sparkle.zip" "$DIST/Lima-Sparkle.sha256" "$DIST/Lima.dmg" "$DIST/Lima.dmg.sha256" "$DIST/Lima-release.json" "$DIST/latest.json" "$DIST/appcast.xml"
rm -rf "$DIST/.release-work/${TAG}"

print '==> Running Swift tests'
make -C "$PROJECT_DIRECTORY" test
print '==> Running installer and update-verifier tests'
"$SCRIPT_DIRECTORY/test_lima_installer.sh"
"$SCRIPT_DIRECTORY/test_update_verifier.sh"
/bin/zsh "$SCRIPT_DIRECTORY/test_approved_lima_update.sh"

print '==> Building model-free signed update app'
RAYPLACEMENT_MODEL_FREE_UPDATE=1 RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 \
    "$SCRIPT_DIRECTORY/package_liamflow_app.sh"
"$SCRIPT_DIRECTORY/create_update_archive.sh" "$DIST"
"$SCRIPT_DIRECTORY/create_sparkle_update_archive.sh" "$DIST"

print '==> Building full signed DMG app'
RAYPLACEMENT_MODEL_FREE_UPDATE=0 RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 \
    "$SCRIPT_DIRECTORY/package_liamflow_app.sh"
RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 \
    "$SCRIPT_DIRECTORY/create_liamflow_dmg.sh" "$DIST"

codesign --verify --deep --strict "$PROJECT_DIRECTORY/build/Lima.app"
(
    cd "$DIST"
    shasum -a 256 --check Lima-Update.sha256
    shasum -a 256 --check Lima-Sparkle.sha256
    shasum -a 256 --check Lima.dmg.sha256
)
release_write_metadata "$TAG"
release_generate_distribution_metadata "$TAG"
release_assert_distribution_metadata "$TAG"
print "Build complete for $TAG"
print "  metadata: $DIST/Lima-release.json"
print "  next:     ./scripts/release_stage.sh --tag $TAG"
