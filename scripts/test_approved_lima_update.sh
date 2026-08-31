#!/bin/zsh
# All fixtures stay in one disposable directory; no installed apps or folder
# permissions are modified, and this test never invokes an admin prompt.
set -euo pipefail
ROOT="${0:A:h:h}"
FIXTURE="$(mktemp -d /private/tmp/lima-approval-test.XXXXXX)"
trap '/bin/rm -rf "$FIXTURE"' EXIT
PROGRAM="$ROOT/scripts/approved_lima_replacement.sh"
for script in "$PROGRAM" "$ROOT/scripts/request_lima_update_approval.sh" "$ROOT/scripts/apply_downloaded_update.sh"; do
    /bin/zsh -n "$script"
done
/usr/bin/osacompile -o "$FIXTURE/approval.scpt" "$ROOT/scripts/authorize_lima_update.applescript"
# Verify the real AppleScript argument quoting without requesting privileges.
/usr/bin/sed 's/ with administrator privileges//' "$ROOT/scripts/authorize_lima_update.applescript" > "$FIXTURE/quoting.applescript"
QUOTED_OUTPUT="$(/usr/bin/osascript "$FIXTURE/quoting.applescript" 'printf "%s\\n" "$@"' "$FIXTURE/a path.app" "O'Brien" '\$(must_not_execute)' 'x; exit 99' '' last | /usr/bin/tr '\r' '\n')"
EXPECTED_OUTPUT="$(printf '%s\n' "$FIXTURE/a path.app" "O'Brien" '\$(must_not_execute)' 'x; exit 99' '' last)"
[[ "$QUOTED_OUTPUT" == "$EXPECTED_OUTPUT" ]]
make_app() {
    local app="$1" version="$2" binary="$3" identity="${4:--}"
    /bin/mkdir -p "$app/Contents/MacOS"
    /bin/cp "$binary" "$app/Contents/MacOS/Lima"
    /bin/mkdir -p "$app/Contents/Resources/Updater"
    /bin/cp "$ROOT/scripts/approved_lima_replacement.sh" "$ROOT/scripts/authorize_lima_update.applescript" "$app/Contents/Resources/Updater/"
    printf 'Permission test fixture\n' > "$app/Contents/Resources/ModeFixture.txt"
    local plist="$app/Contents/Info.plist"
    /usr/bin/plutil -create xml1 "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.liam.lima' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Lima' "$plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$plist"
    if [[ "$identity" == - ]]; then
        /usr/bin/codesign --force --sign - "$app" >/dev/null 2>&1
    else
        /bin/zsh "$ROOT/scripts/sign_lima_app.sh" "$app"
    fi
}
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
expect_failure() {
    if /bin/zsh -f "$PROGRAM" "$@" > "$FIXTURE/last-test.log" 2>&1; then
        echo 'FAIL: unsafe replacement was accepted'; exit 1
    fi
}
SOURCE="$FIXTURE/Incoming.app"
TARGET="$FIXTURE/Protected Applications/Lima.app"
make_app "$SOURCE" 3.2.3 /usr/bin/false
make_app "$TARGET" 3.2.2 /usr/bin/true
next_transaction() { print -r -- "${TARGET:h}/.lima-install.$(/usr/bin/uuidgen)"; }
expect_failure "$SOURCE" "$TARGET" 3.2.3 3.2.3 2147483646 "$(next_transaction)"
/usr/bin/grep -q 'signed Lima installation' "$FIXTURE/last-test.log"
[[ "$(version "$TARGET")" == 3.2.2 ]]
/bin/ln -s "$TARGET" "$FIXTURE/Linked.app"
expect_failure "$SOURCE" "$FIXTURE/Linked.app" 3.2.3 3.2.3 2147483646 "$FIXTURE/.lima-install.ABCD"
expect_failure "$SOURCE" "$TARGET" 3.2.3 3.2.3 1 "$(next_transaction)"
expect_failure "$SOURCE" "$TARGET" 3.2.3 3.2.3 2147483646 "$FIXTURE/.lima-install.ABCD"
expect_failure "$SOURCE" "$TARGET" 3.2.3 3.2.3 2147483646 "${TARGET:h}/.lima-install.not-a-uuid"
echo 'PASS: approval syntax, argument quoting, ad-hoc rejection, symlink rejection, process and staging-path validation.'

if [[ "${LIMA_TEST_STABLE_SIGNING:-0}" != 1 ]]; then
    echo 'SKIP: certificate-backed replacement tests (set LIMA_TEST_STABLE_SIGNING=1 to use the existing Lima signing identity).'
    exit 0
fi
make_app "$SOURCE" 3.2.3 /usr/bin/false stable
make_app "$TARGET" 3.2.2 /usr/bin/true stable
/usr/bin/chgrp "$(/usr/bin/id -g)" "$SOURCE/Contents/Resources/ModeFixture.txt"
/bin/chmod 6755 "$SOURCE/Contents/Resources/ModeFixture.txt"
/bin/chmod +a 'everyone allow write' "$SOURCE/Contents/Resources/ModeFixture.txt"
TRANSACTION="$(next_transaction)"
/bin/zsh -f "$PROGRAM" "$SOURCE" "$TARGET" 3.2.3 3.2.3 2147483646 "$TRANSACTION"
[[ "$(version "$TARGET")" == 3.2.3 && "$(version "$TRANSACTION/Previous.app")" == 3.2.2 ]]
/usr/bin/codesign --verify --deep --strict "$TARGET"
[[ ! -u "$TARGET/Contents/Resources/ModeFixture.txt" && ! -g "$TARGET/Contents/Resources/ModeFixture.txt" ]]
if /bin/ls -le "$TARGET/Contents/Resources/ModeFixture.txt" | /usr/bin/grep -q 'allow write'; then
    echo 'FAIL: copied a write-grant ACL into the installed app'; exit 1
fi
# Exercise the actual unprivileged approval coordinator, replacing only the
# OS dialog executable in a disposable copy so no credential prompt appears.
/usr/bin/sed 's|^/usr/bin/osascript |"'"$ROOT"'/Tests/UpdaterFixtures/cancel-authorization" |' "$ROOT/scripts/request_lima_update_approval.sh" > "$FIXTURE/cancel-request.sh"
/bin/sleep 20 &
HELD_PID=$!
if /bin/zsh -f "$FIXTURE/cancel-request.sh" "$HELD_PID" "$SOURCE" "$TARGET" 3.2.3 3.2.3 "$(next_transaction)" "$FIXTURE/progress" "$FIXTURE/authorization.log"; then
    echo 'FAIL: canceled authorization reported success'; exit 1
else
    [[ $? == 125 ]]
fi
/bin/kill -0 "$HELD_PID"
/bin/kill "$HELD_PID"
[[ "$(version "$TARGET")" == 3.2.3 ]]
if /usr/bin/grep -q '^ready$' "$FIXTURE/progress"; then
    echo 'FAIL: cancellation requested app shutdown'; exit 1
fi
# Spaces/apostrophes in app names are data, never commands.
TARGET="$FIXTURE/Liam's Apps/Lima's copy.app"
make_app "$TARGET" 3.2.2 /usr/bin/true stable
/bin/zsh -f "$PROGRAM" "$SOURCE" "$TARGET" 3.2.3 3.2.3 2147483646 "$(next_transaction)"
[[ "$(version "$TARGET")" == 3.2.3 ]]
expect_failure "$SOURCE" "$TARGET" 9.9.9 3.2.3 2147483646 "$(next_transaction)"
make_app "$FIXTURE/Adhoc.app" 3.2.4 /usr/bin/true
expect_failure "$FIXTURE/Adhoc.app" "$TARGET" 3.2.4 3.2.4 2147483646 "$(next_transaction)"
# Failure injection changes only a disposable copy of the program, not the
# production installer or its environment. The real rollback branch runs.
/usr/bin/sed 's|^/bin/mv "$STAGED" "$DESTINATION_APP"$|/usr/bin/false|' "$PROGRAM" > "$FIXTURE/fail-swap.sh"
TRANSACTION="$(next_transaction)"
if /bin/zsh -f "$FIXTURE/fail-swap.sh" "$SOURCE" "$TARGET" 3.2.3 3.2.3 2147483646 "$TRANSACTION"; then
    echo 'FAIL: injected swap failure did not fail'; exit 1
fi
[[ "$(version "$TARGET")" == 3.2.3 && ! -e "$TRANSACTION/Previous.app" ]]
/usr/bin/codesign --verify --deep --strict "$TARGET"
/usr/bin/sed 's|^/usr/bin/codesign --verify --deep --strict -R "=$REQUIREMENT" "$DESTINATION_APP"$|/usr/bin/false|' "$PROGRAM" > "$FIXTURE/fail-verification.sh"
TRANSACTION="$(next_transaction)"
if /bin/zsh -f "$FIXTURE/fail-verification.sh" "$SOURCE" "$TARGET" 3.2.3 3.2.3 2147483646 "$TRANSACTION"; then
    echo 'FAIL: injected final verification failure did not fail'; exit 1
fi
[[ -d "$TRANSACTION/Failed.app" && ! -e "$TRANSACTION/Previous.app" ]]
/usr/bin/codesign --verify --deep --strict "$TARGET"
# A held process keeps the original app in place until the parent signals exit.
/bin/sleep 20 &
HELD_PID=$!
TRANSACTION="$(next_transaction)"
/bin/zsh -f "$PROGRAM" "$SOURCE" "$TARGET" 3.2.3 3.2.3 "$HELD_PID" "$TRANSACTION" &
INSTALL_PID=$!
for _ in {1..100}; do
    [[ -f "$TRANSACTION/Ready" ]] && break
    /bin/sleep 0.05
done
[[ -f "$TRANSACTION/Ready" && ! -e "$TRANSACTION/Previous.app" ]]
/bin/kill "$HELD_PID"
wait "$INSTALL_PID"
[[ -d "$TRANSACTION/Previous.app" ]]
echo 'PASS: signed replacement, exact paths, version/signer rejection, rollback, cancellation, mode/ACL sanitization, and staging before process exit.'
