#!/bin/zsh
# Build, verify, upload, and optionally publish a Lima release.
# Usage: ./scripts/deploy_lima.sh [--tag vX.Y.Z] [--publish] [--keep-work]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG=""
SCRIPT_NAME="${0:t}"
PUBLISH=0
KEEP_WORK=0

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [options]

Options:
  --tag vX.Y.Z   Release tag; defaults to the version in Packaging/Info.plist
  --publish      Publish the verified release; otherwise leave it as a draft
  --keep-work    Keep temporary DMG split parts under /tmp for troubleshooting
  -h, --help     Show this help
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --tag) TAG="${2:?--tag requires a value}"; shift 2;;
    --publish) PUBLISH=1; shift;;
    --keep-work) KEEP_WORK=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2;;
  esac
done

require_cmd() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
for cmd in gh swift codesign shasum rsync hdiutil split; do require_cmd "$cmd"; done
[[ -f "$PROJECT_DIR/Package.swift" ]] || { echo "Not a Lima project: $PROJECT_DIR" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Packaging/Info.plist")"
[[ -n "$TAG" ]] || TAG="v$VERSION"
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Invalid tag: $TAG" >&2; exit 1; }
[[ "$TAG" == "v$VERSION" ]] || { echo "Tag $TAG does not match app version $VERSION" >&2; exit 1; }
gh auth status >/dev/null

# Swift builds plus the full DMG require several GB of transient storage.
AVAILABLE_KB="$(df -Pk "$PROJECT_DIR" | awk 'NR==2 {print $4}')"
MINIMUM_KB=$((5 * 1024 * 1024))
(( AVAILABLE_KB >= MINIMUM_KB )) || {
  echo "Insufficient disk space: need at least 5 GB free, have $((AVAILABLE_KB / 1024 / 1024)) GB" >&2
  exit 1
}

SIGN_DIR="$HOME/Library/Application Support/RayPlacement/Signing"
SIGN_KEYCHAIN="$SIGN_DIR/RayPlacementSigning.keychain-db"
SIGN_PASSWORD="$SIGN_DIR/keychain-password"
[[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_PASSWORD" ]] || {
  echo "Stable Lima signing identity is unavailable: $SIGN_KEYCHAIN" >&2; exit 1
}
IDENTITY="$(security find-identity -v -p codesigning "$SIGN_KEYCHAIN" | awk '/RayPlacement Local Code Signing/ {print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo "Stable signing identity is not trusted for code signing" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR%/}/lima-deploy.XXXXXX")"
PART_DIR="$WORK_DIR/parts"
cleanup() {
  if (( KEEP_WORK == 0 )); then rm -rf "$WORK_DIR"; else echo "Kept work directory: $WORK_DIR"; fi
}
trap cleanup EXIT INT TERM
mkdir -p "$PART_DIR"

export RAYPLACEMENT_SCRATCH_DIRECTORY="${RAYPLACEMENT_SCRATCH_DIRECTORY:-$HOME/.cache/lima-build}"
export RAYPLACEMENT_MODULE_CACHE_DIRECTORY="${RAYPLACEMENT_MODULE_CACHE_DIRECTORY:-$RAYPLACEMENT_SCRATCH_DIRECTORY/module-cache}"
DIST="$PROJECT_DIR/dist"
mkdir -p "$DIST"

printf '%s\n' "==> Running tests"
make -C "$PROJECT_DIR" test
"$PROJECT_DIR/scripts/test_lima_installer.sh"
/bin/zsh "$PROJECT_DIR/scripts/test_approved_lima_update.sh"

printf '%s\n' "==> Building signed update archive"
RAYPLACEMENT_MODEL_FREE_UPDATE=1 RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 \
  "$PROJECT_DIR/scripts/package_liamflow_app.sh"
"$PROJECT_DIR/scripts/create_update_archive.sh" "$DIST"

printf '%s\n' "==> Building signed DMG"
RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 \
  "$PROJECT_DIR/scripts/package_liamflow_app.sh"
RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 \
  "$PROJECT_DIR/scripts/create_liamflow_dmg.sh" "$DIST"

codesign --verify --deep --strict "$PROJECT_DIR/build/Lima.app"
(
  cd "$DIST"
  shasum -a 256 --check Lima-Update.sha256
  shasum -a 256 --check Lima.dmg.sha256
)
UPDATE_SHA="$(shasum -a 256 "$DIST/Lima-Update.zip" | awk '{print $1}')"
DMG_SHA="$(shasum -a 256 "$DIST/Lima.dmg" | awk '{print $1}')"

printf '%s\n' "==> Creating or updating draft release $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  IS_DRAFT="$(gh release view "$TAG" --json isDraft --jq .isDraft)"
  [[ "$IS_DRAFT" == true ]] || { echo "$TAG is already published; refusing to overwrite it" >&2; exit 1; }
else
  gh release create "$TAG" --draft --title "Lima $TAG" --generate-notes
fi
gh release upload "$TAG" \
  "$DIST/Lima-Update.zip" "$DIST/Lima-Update.sha256" "$DIST/Lima.dmg.sha256" --clobber

printf '%s\n' "==> Uploading DMG"
if ! gh release upload "$TAG" "$DIST/Lima.dmg" --clobber; then
  echo "Direct DMG upload failed; using verified multipart workflow."
  split -b 24m -a 2 "$DIST/Lima.dmg" "$PART_DIR/Lima.dmg.part-"
  PART_COUNT="$(find "$PART_DIR" -type f -name 'Lima.dmg.part-*' | wc -l | tr -d ' ')"
  for part in "$PART_DIR"/Lima.dmg.part-*; do gh release upload "$TAG" "$part" --clobber; done
  gh workflow run assemble-signed-dmg.yml \
    -f release_tag="$TAG" -f sha256="$DMG_SHA" -f part_count="$PART_COUNT"
  RUN_ID="$(gh run list --workflow assemble-signed-dmg.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
  gh run watch "$RUN_ID" --exit-status
fi

for pair in "Lima-Update.zip:$UPDATE_SHA" "Lima.dmg:$DMG_SHA"; do
  asset="${pair%%:*}"; expected="${pair##*:}"
  api_url="$(gh release view "$TAG" --json assets --jq ".assets[] | select(.name == \"$asset\") | .apiUrl")"
  actual="$(gh api "$api_url" --jq .digest)"
  [[ "$actual" == "sha256:$expected" ]] || { echo "GitHub digest mismatch for $asset" >&2; exit 1; }
  echo "$asset verified: $actual"
done

if (( PUBLISH == 1 )); then
  gh release edit "$TAG" --draft=false
  echo "Published: https://github.com/hosfeldli/ray-placement/releases/tag/$TAG"
else
  echo "Verified draft is ready. Re-run with --publish to publish it."
fi
