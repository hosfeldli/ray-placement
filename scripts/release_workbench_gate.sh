#!/bin/zsh
# Deterministic stabilization gate for every Lima release build and stage.
# Run --live separately on a signed-in developer Mac to exercise real Codex
# native-tool routing; hosted runners must not require a personal CLI session.
set -euo pipefail

RUN_LIVE=0
if (( $# > 0 )); then
    [[ $# == 1 && "$1" == --live ]] || {
        print -u2 'Usage: release_workbench_gate.sh [--live]'
        exit 2
    }
    RUN_LIVE=1
fi

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
cd "$PROJECT_DIRECTORY"

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIRECTORY/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIRECTORY/.build/module-cache"

print '==> Workbench Browser, PTY, registry, file, app-server and AI presentation tests'
swift test --disable-sandbox --scratch-path "$PROJECT_DIRECTORY/.build" \
    --filter 'workbenchNative|workbenchRegistry|workbenchDiagnostics|workbenchPresentation|codexAppServerBridge'

if (( RUN_LIVE )); then
    print '==> Workbench live Codex native-tool bridge'
    LIMA_TEST_MODE=1 LIMA_ALLOW_LIVE_AI_TESTS=1 LIMA_WORKBENCH_LIVE_CODEX=1 \
        swift test --disable-sandbox --scratch-path "$PROJECT_DIRECTORY/.build" \
        --filter liveCodexAppServerWorkbenchBridgeSmoke
fi

print 'Workbench release gate passed.'
