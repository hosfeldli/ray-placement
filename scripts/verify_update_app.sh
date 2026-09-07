#!/bin/zsh
set -euo pipefail
APP="${1:?Usage: verify_update_app.sh <app> [expected-version] [expected-build]}"
EXPECTED_VERSION="${2:-}"
EXPECTED_BUILD="${3:-}"
PLIST="$APP/Contents/Info.plist"
value() { /usr/libexec/PlistBuddy -c "Print :$2" "$PLIST"; }
fail() { echo "Update verification failed: $1" >&2; exit 1; }
[[ -d "$APP" && ! -L "$APP" ]] || fail 'app bundle is missing or symbolic'
[[ "$(value CFBundleIdentifier)" == dev.liam.lima ]] || fail 'bundle identifier is not Lima'
[[ "$(value CFBundleExecutable)" == Lima ]] || fail 'bundle executable is not Lima'
[[ -x "$APP/Contents/MacOS/Lima" ]] || fail 'Lima executable is missing'
[[ -z "$EXPECTED_VERSION" || "$(value CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]] || fail 'version mismatch'
[[ -z "$EXPECTED_BUILD" || "$(value CFBundleVersion)" == "$EXPECTED_BUILD" ]] || fail 'build mismatch'
/usr/bin/codesign --verify --deep --strict "$APP" || fail 'code signature is invalid'
# Never accept links or executable content outside the expected app layout.
while IFS= read -r item; do
    [[ -L "$item" ]] && fail "symbolic link found: $item"
done < <(/usr/bin/find "$APP" -mindepth 1 -print)
echo "Verified update app: $APP"
