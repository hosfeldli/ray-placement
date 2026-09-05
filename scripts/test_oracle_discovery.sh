#!/bin/zsh
# Read-only integration test against the explicitly named local Oracle fixture.
set -euo pipefail
ROOT="${0:A:h:h}"
CONTAINER="${1:-lima-oracle-test}"
OUTPUT="$(mktemp "${TMPDIR:-/tmp}/lima-oracle-discovery.XXXXXX")"
trap 'rm -f "$OUTPUT"' EXIT
{
    printf '%s\n' 'WHENEVER SQLERROR EXIT SQL.SQLCODE' 'SET FEEDBACK OFF' 'SET MARKUP CSV ON DELIMITER | QUOTE ON' 'SET LONG 1000000 LONGCHUNKSIZE 1000000'
    sed -n '/private static func tablesQuery/,/^private struct SQLLocalCollection/p' "$ROOT/Sources/RayPlacement/SQLWorkspaceWindowController.swift" |
        awk '/case .oracle:/ { oracle=1; next } oracle && /return "/ { sub(/^ *return "/, ""); sub(/"$/, ";"); print; oracle=0 }'
    printf '%s\n' 'EXIT'
} | docker exec -i "$CONTAINER" sqlplus -s / as sysdba > "$OUTPUT" || {
    grep -n -E 'ORA-|SP2-' "$OUTPUT" || true
    exit 1
}
echo "All six Oracle discovery queries completed successfully ($(wc -l < "$OUTPUT" | tr -d ' ') output lines)."
