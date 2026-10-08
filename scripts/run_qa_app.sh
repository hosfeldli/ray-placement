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

# The app's in-process QA listener starts only with both independent runtime
# opt-ins. Running this helper launches the QA app directly with those variables.
LIMA_TEST_MODE=1 LIMA_ENABLE_QA_MCP=1 exec "$LIMA_EXECUTABLE"
