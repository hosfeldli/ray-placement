#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
SOURCE_APP="$PROJECT_DIRECTORY/build/RayPlacement.app"
APP_DIRECTORY="$PROJECT_DIRECTORY/build/Lima.app"

"$PROJECT_DIRECTORY/scripts/package_app.sh"

rm -rf "$APP_DIRECTORY"
ditto "$SOURCE_APP" "$APP_DIRECTORY"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Lima' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Lima' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.liam.lima' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Lima' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSAccessibilityUsageDescription Lima uses Accessibility only when you ask it to read and replace selected text, resize windows, lock the screen, or paste into another app.' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSAppleEventsUsageDescription Lima uses Apple Events only to show the current Apple Music or Spotify track and run the playback controls you press.' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription Lima records audio only after you press Dictate in Notes and transcribes short local segments on this Mac.' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSSpeechRecognitionUsageDescription Lima uses on-device speech recognition to transcribe short recorded segments into the note you chose.' "$APP_DIRECTORY/Contents/Info.plist"
mv "$APP_DIRECTORY/Contents/MacOS/RayPlacement" "$APP_DIRECTORY/Contents/MacOS/Lima"
cp "$PROJECT_DIRECTORY/Uninstall Lima.command" "$APP_DIRECTORY/Contents/Resources/Uninstall Lima.command"
chmod 755 "$APP_DIRECTORY/Contents/Resources/Uninstall Lima.command"
# A fresh Git checkout and a local build can carry different Finder metadata.
# It is never part of an app bundle and can make an otherwise valid ad-hoc
# signature fail on a hosted macOS runner.
xattr -cr "$APP_DIRECTORY"
if ! codesign --force --deep --sign - "$APP_DIRECTORY"; then
    echo "Could not apply Lima's local ad-hoc signature." >&2
    exit 1
fi
"$PROJECT_DIRECTORY/scripts/verify_liamflow_app.sh" "$APP_DIRECTORY"
echo "Packaged: $APP_DIRECTORY"
