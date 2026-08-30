#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/lima-installer-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
make_app() {
    local app="$1" version="$2" binary="$3"
    mkdir -p "$app/Contents/MacOS"
    cp "$binary" "$app/Contents/MacOS/Lima"
    local plist="$app/Contents/Info.plist"
    plutil -create xml1 "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.liam.lima' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Lima' "$plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$plist"
    codesign --force --sign - "$app" >/dev/null 2>&1
}
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
SOURCE="$FIXTURE/Release.app"
make_app "$SOURCE" 3.1.4 /usr/bin/false
for folder in 'Applications' 'User Applications' 'Custom Folder'; do
    mkdir -p "$FIXTURE/$folder"
    TARGET="$FIXTURE/$folder/Lima.app"
    make_app "$TARGET" 3.1.3 /usr/bin/true
    TRANSACTION="$(mktemp -d "$FIXTURE/$folder/.lima-install.XXXXXX")"
    /bin/zsh "$ROOT/scripts/replace_lima_bundle.sh" "$SOURCE" "$TARGET" 3.1.4 "$TRANSACTION"
    [[ "$(version "$TARGET")" == 3.1.4 && "$(version "$TRANSACTION/Previous.app")" == 3.1.3 ]]
done
TARGET="$FIXTURE/Applications/Lima.app"
TRANSACTION="$(mktemp -d "$FIXTURE/Applications/.lima-install.XXXXXX")"
if /bin/zsh "$ROOT/scripts/replace_lima_bundle.sh" "$SOURCE" "$TARGET" 9.9.9 "$TRANSACTION"; then
    echo 'FAIL: accepted a mismatched release version'; exit 1
fi
[[ "$(version "$TARGET")" == 3.1.4 ]]
make_app "$FIXTURE/Next.app" 3.1.5 /usr/bin/true
TRANSACTION="$(mktemp -d "$FIXTURE/Applications/.lima-install.XXXXXX")"
if LIMA_TEST_SWAP_FAILURE=1 PATH="$ROOT/Tests/UpdaterFixtures:$PATH" /bin/zsh "$ROOT/scripts/replace_lima_bundle.sh" "$FIXTURE/Next.app" "$TARGET" 3.1.5 "$TRANSACTION"; then
    echo 'FAIL: expected injected replacement failure'; exit 1
fi
[[ "$(version "$TARGET")" == 3.1.4 ]]
codesign --verify --deep --strict "$TARGET"
TRANSACTION="$(mktemp -d "$FIXTURE/Applications/.lima-install.XXXXXX")"
if LIMA_TEST_CORRUPT_SWAP=1 PATH="$ROOT/Tests/UpdaterFixtures:$PATH" /bin/zsh "$ROOT/scripts/replace_lima_bundle.sh" "$FIXTURE/Next.app" "$TARGET" 3.1.5 "$TRANSACTION"; then
    echo 'FAIL: expected verification failure after replacement'; exit 1
fi
[[ "$(version "$TARGET")" == 3.1.4 ]]
codesign --verify --deep --strict "$TARGET"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion tampered' "$FIXTURE/Next.app/Contents/Info.plist"
TRANSACTION="$(mktemp -d "$FIXTURE/Applications/.lima-install.XXXXXX")"
if /bin/zsh "$ROOT/scripts/replace_lima_bundle.sh" "$FIXTURE/Next.app" "$TARGET" 3.1.5 "$TRANSACTION"; then
    echo 'FAIL: accepted a tampered app'; exit 1
fi
[[ "$(version "$TARGET")" == 3.1.4 ]]
ln -s "$TARGET" "$FIXTURE/Linked.app"
TRANSACTION="$(mktemp -d "$FIXTURE/.lima-install.XXXXXX")"
if /bin/zsh "$ROOT/scripts/replace_lima_bundle.sh" "$SOURCE" "$FIXTURE/Linked.app" 3.1.4 "$TRANSACTION"; then
    echo 'FAIL: accepted a symlink target'; exit 1
fi
echo 'PASS: exact installation paths, paths with spaces, backups, version rejection, rollback, and signature rejection.'
