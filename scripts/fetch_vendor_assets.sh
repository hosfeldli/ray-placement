#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"

"$SCRIPT_DIRECTORY/assemble_whisper_model.sh"

test -x "$PROJECT_DIRECTORY/Packaging/WhisperRuntime/whisper-cli"
test -x "$PROJECT_DIRECTORY/Packaging/Vendor/Harper/harper-cli"
test -x "$PROJECT_DIRECTORY/Packaging/Vendor/PythonGrammar/grammar_check.py"
test -d "$PROJECT_DIRECTORY/Packaging/Vendor/PythonGrammar/site-packages/spellchecker"

echo "Verified RayPlacement's dictation and rule-based writing assets."
echo "Dictation is the only bundled model-powered feature."
