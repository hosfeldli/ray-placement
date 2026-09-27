#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
source "$SCRIPT_DIRECTORY/release_config.sh"
lima_release_validate_signing_policy
lima_release_export_packaging_policy
APP_DIRECTORY="$PROJECT_DIRECTORY/build/Lima.app"
export LIMA_BROWSER_BRIDGE_SIGNED_XPI="${LIMA_BROWSER_BRIDGE_SIGNED_XPI:-}"
export LIMA_BROWSER_BRIDGE_SIGNED_XPI_SHA256="${LIMA_BROWSER_BRIDGE_SIGNED_XPI_SHA256:-}"

if [[ "${RAYPLACEMENT_DISABLE_LOCAL_SIGNING:-0}" == "1" ]]; then
    "$PROJECT_DIRECTORY/scripts/package_app.sh"
else
    RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 "$PROJECT_DIRECTORY/scripts/package_app.sh"
fi

# package_app.sh produces the final Lima identity directly. Re-signing is
# unnecessary and would only invalidate verification if the bundle changed.
"$PROJECT_DIRECTORY/scripts/verify_liamflow_app.sh" "$APP_DIRECTORY"
echo "Packaged: $APP_DIRECTORY"
