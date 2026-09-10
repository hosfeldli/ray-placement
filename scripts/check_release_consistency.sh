#!/bin/zsh
# Validate the single source of release version truth.
set -euo pipefail

ROOT="${0:A:h}/.."
PLIST="$ROOT/Packaging/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
[[ "$VERSION" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' ]] || { print -u2 "Invalid plist version: $VERSION"; exit 1; }
EXPECTED_BUILD="${VERSION//./}"
[[ "$BUILD" == "$EXPECTED_BUILD" ]] || { print -u2 "Build $BUILD does not match version $VERSION; expected $EXPECTED_BUILD"; exit 1; }
plutil -lint "$PLIST" >/dev/null
print "Lima release metadata consistent: $VERSION ($BUILD)"
