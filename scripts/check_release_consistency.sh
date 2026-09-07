#!/bin/zsh
set -euo pipefail
root=${0:A:h}/..
plist="$root/Packaging/Info.plist"
readme="$root/README.md"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
readme_version=$(sed -nE '1s/^# Lima ([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' "$readme")
[[ -n "$readme_version" ]] || { print -u2 "README version is missing"; exit 1; }
[[ "$readme_version" == "$version" ]] || { print -u2 "README version $readme_version does not match plist version $version (build $build)"; exit 1; }
print "Lima release metadata consistent: $version ($build)"
