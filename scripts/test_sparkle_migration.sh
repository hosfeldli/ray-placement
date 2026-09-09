#!/bin/zsh
# Validate the optional Sparkle migration package graph without resolving or
# downloading dependencies. The default graph remains Sparkle-free, while the
# explicit migration graph exposes Sparkle and its compile condition.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/lima-sparkle-migration.XXXXXX")"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

swift package --package-path "$PROJECT_DIRECTORY" dump-package > "$TEMP_DIRECTORY/default.json"
LIMA_ENABLE_SPARKLE_MIGRATION=1 swift package --package-path "$PROJECT_DIRECTORY" dump-package > "$TEMP_DIRECTORY/migration.json"

jq -e '
    ([.dependencies[]?.sourceControl[]?.identity] | index("sparkle")) == null and
    (([.targets[] | select(.name == "RayPlacement") | .dependencies[]?.product[0]] | index("Sparkle")) == null)
' "$TEMP_DIRECTORY/default.json" >/dev/null

jq -e '
    ([.dependencies[]?.sourceControl[]?.identity] | index("sparkle")) != null and
    ([.dependencies[] | select(.sourceControl[]?.identity == "sparkle") | .sourceControl[0].requirement.exact[0]] | index("2.6.4")) != null and
    ([.targets[] | select(.name == "RayPlacement") | .dependencies[]?.product[0]] | index("Sparkle")) != null and
    ([.targets[] | select(.name == "RayPlacement") | .settings[]?.kind.define._0] | index("LIMA_SPARKLE_MIGRATION")) != null
' "$TEMP_DIRECTORY/migration.json" >/dev/null

print 'Sparkle migration package graph passed.'
