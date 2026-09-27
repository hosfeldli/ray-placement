#!/bin/zsh
# Validate the single source of release version truth.
set -euo pipefail

ROOT="${0:A:h}/.."
PLIST="$ROOT/Packaging/Info.plist"
source "$ROOT/scripts/release_config.sh"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
EXPECTED_BUILD="$(lima_release_build_number "$VERSION")"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || { print -u2 "Build $BUILD does not match version $VERSION; expected $EXPECTED_BUILD"; exit 1; }
plutil -lint "$PLIST" >/dev/null
print "Lima release metadata consistent: $VERSION ($BUILD)"
