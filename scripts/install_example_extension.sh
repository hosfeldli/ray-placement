#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
DESTINATION_DIRECTORY="$HOME/Library/Application Support/RayPlacement/Extensions/project-tools"

if [[ -e "$DESTINATION_DIRECTORY/manifest.json" ]]; then
    echo "The example is already installed at: $DESTINATION_DIRECTORY"
    echo "Move or rename that folder before installing a fresh copy."
    exit 1
fi

mkdir -p "$DESTINATION_DIRECTORY"
cp -R "$PROJECT_DIRECTORY/Examples/project-tools/." "$DESTINATION_DIRECTORY/"
chmod 755 "$DESTINATION_DIRECTORY/bin/system-summary"

echo "Installed the example in: $DESTINATION_DIRECTORY"
echo "Choose Reload Extensions in RayPlacement to use it."
