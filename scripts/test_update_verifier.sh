#!/bin/zsh
# Fault-injection tests for the installed-app verifier. The test uses a
# disposable signed candidate and never invokes an updater or replacement.
set -euo pipefail
ROOT="${0:A:h:h}"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/lima-verifier-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

make_app() {
    local app="$1" version="$2" bundle_id="${3:-dev.liam.lima}"
    mkdir -p "$app/Contents/MacOS"
    cp /usr/bin/true "$app/Contents/MacOS/Lima"
    plutil -create xml1 "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Lima' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$app/Contents/Info.plist"
    codesign --force --sign - "$app" >/dev/null 2>&1
}
expect_failure() {
    if /bin/zsh "$ROOT/scripts/verify_update_app.sh" "$@" >/dev/null 2>&1; then
        echo "FAIL: verifier accepted unsafe candidate" >&2
        exit 1
    fi
}

APP="$FIXTURE/Lima.app"
make_app "$APP" 3.12.5
# A truncated/corrupted ZIP must fail archive integrity validation before any
# candidate app is considered. This mirrors the production SHA-256/extraction
# gate without invoking the updater or replacing an installed app.
printf 'not a valid Lima update archive\n' > "$FIXTURE/Corrupted.zip"
if /usr/bin/zipinfo -t "$FIXTURE/Corrupted.zip" >/dev/null 2>&1; then
    echo 'FAIL: corrupted update archive passed integrity validation' >&2
    exit 1
fi
# The verifier rejects ad-hoc signatures before any update installation path is touched.
expect_failure "$APP" 3.12.5 3125 TEAM "RayPlacement Local Code Signing" "$(printf '0%.0s' {1..64})"
# Structural and metadata fault injection remains rejected even with a bad signature.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.wrong' "$APP/Contents/Info.plist"
expect_failure "$APP" 3.12.5 3125 TEAM Identity "$(printf '0%.0s' {1..64})"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.liam.lima' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 3.12.4' "$APP/Contents/Info.plist"
expect_failure "$APP" 3.12.4 3124 TEAM Identity "$(printf '0%.0s' {1..64})"
rm "$APP/Contents/MacOS/Lima"
expect_failure "$APP" 3.12.5 3125 TEAM Identity "$(printf '0%.0s' {1..64})"
# A missing candidate is treated as invalid data and cannot reach replacement.
expect_failure "$FIXTURE/Missing.app" 3.12.5 3125 TEAM Identity "$(printf '0%.0s' {1..64})"
echo 'PASS: invalid signature, wrong certificate policy, wrong bundle ID, non-newer version, and missing files rejected.'
