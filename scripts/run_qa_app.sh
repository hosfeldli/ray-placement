#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP_DIRECTORY="${1:-$PROJECT_DIRECTORY/build/Lima Test.app}"
LIMA_EXECUTABLE="$APP_DIRECTORY/Contents/MacOS/Lima"

if [[ ! -x "$LIMA_EXECUTABLE" ]]; then
    echo "QA app executable is missing: $LIMA_EXECUTABLE" >&2
    exit 1
fi

# Launch the isolated QA-branded app in test mode.
LIMA_TEST_MODE=1 exec "$LIMA_EXECUTABLE"
