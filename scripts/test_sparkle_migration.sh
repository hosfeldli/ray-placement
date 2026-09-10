#!/bin/zsh
# Validate that Sparkle is a permanent, pinned dependency and that the updater
# bridge is present without requiring Sparkle to become the production backend.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/lima-sparkle-migration.XXXXXX")"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

swift package --package-path "$PROJECT_DIRECTORY" dump-package > "$TEMP_DIRECTORY/package.json"

jq -e '
    ([.dependencies[]?.sourceControl[]?.identity] | index("sparkle")) != null and
    ([.dependencies[] | select(.sourceControl[]?.identity == "sparkle") | .sourceControl[0].requirement.exact[0]] | index("2.9.6")) != null and
    ([.targets[] | select(.name == "RayPlacement") | .dependencies[]?.product[0]] | index("Sparkle")) != null
' "$TEMP_DIRECTORY/package.json" >/dev/null

if grep -R -n -E 'LIMA_ENABLE_SPARKLE_MIGRATION|LIMA_SPARKLE_MIGRATION' \
    "$PROJECT_DIRECTORY/Package.swift" \
    "$PROJECT_DIRECTORY/Sources" \
    "$PROJECT_DIRECTORY/Package.swift" \
    "$PROJECT_DIRECTORY/Sources" >/dev/null 2>&1; then
    print -u2 'Removed Sparkle migration flags are still referenced.'
    exit 1
fi

PLIST="$PROJECT_DIRECTORY/Packaging/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")" == "https://github.com/hosfeldli/ray-placement/releases/latest/download/appcast.xml" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" == "Lt/Wlxc0rmkpNrz0YQ4hBpgeO51ynD+yALaUtE45f0c=" ]]

grep -q 'activeBackend' "$PROJECT_DIRECTORY/Sources/RayPlacement/SparkleMigrationBoundary.swift"
grep -q 'SPUStandardUpdaterController' "$PROJECT_DIRECTORY/Sources/RayPlacement/SparkleMigrationBoundary.swift"

print 'Permanent Sparkle 2.9.6 bridge package graph passed.'
