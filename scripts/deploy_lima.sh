#!/bin/zsh
# Compatibility entry point. The old monolithic deployment command now uses
# the staged, resumable release lifecycle. See docs/RELEASING.md.
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
exec "$SCRIPT_DIRECTORY/release.sh" deploy "$@"
