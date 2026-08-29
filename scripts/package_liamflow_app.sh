#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
SOURCE_APP="$PROJECT_DIRECTORY/build/RayPlacement.app"
APP_DIRECTORY="$PROJECT_DIRECTORY/build/LiamFlow.app"

"$PROJECT_DIRECTORY/scripts/package_app.sh"

rm -rf "$APP_DIRECTORY"
ditto "$SOURCE_APP" "$APP_DIRECTORY"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName LiamFlow' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable LiamFlow' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.liam.liamflow' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName LiamFlow' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSAccessibilityUsageDescription LiamFlow uses Accessibility only when you ask it to read and replace selected text, resize windows, lock the screen, or paste into another app.' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSAppleEventsUsageDescription LiamFlow uses Apple Events only to show the current Apple Music or Spotify track and run the playback controls you press.' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription LiamFlow records audio only after you press Dictate in Notes and transcribes short local segments on this Mac.' "$APP_DIRECTORY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :NSSpeechRecognitionUsageDescription LiamFlow uses on-device speech recognition to transcribe short recorded segments into the note you chose.' "$APP_DIRECTORY/Contents/Info.plist"
mv "$APP_DIRECTORY/Contents/MacOS/RayPlacement" "$APP_DIRECTORY/Contents/MacOS/LiamFlow"
cp "$PROJECT_DIRECTORY/Uninstall LiamFlow.command" "$APP_DIRECTORY/Contents/Resources/Uninstall LiamFlow.command"
chmod 755 "$APP_DIRECTORY/Contents/Resources/Uninstall LiamFlow.command"
codesign --force --deep --sign - "$APP_DIRECTORY"
"$PROJECT_DIRECTORY/scripts/verify_liamflow_app.sh" "$APP_DIRECTORY"
echo "Packaged: $APP_DIRECTORY"
