#!/bin/zsh
# Regression tests for Sparkle/CFBundleVersion ordering.
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
source "$SCRIPT_DIRECTORY/release_config.sh"

assert_build() {
    local version="$1"
    local expected="$2"
    local actual="$(lima_release_build_number "$version")"
    [[ "$actual" == "$expected" ]] || {
        print -u2 "Unexpected build for $version: got $actual, expected $expected"
        exit 1
    }
}

assert_build 3.12.21 3012021
assert_build 3.13.0 3013000
assert_build 3.13.1 3013001
assert_build 3.14.0 3014000
assert_build 4.0.0 4000000

# The corrective build must be newer than the historical 3.12.21 build.
lima_release_assert_build_increases 3013001 31221
if lima_release_assert_build_increases 3130 31221 >/dev/null 2>&1; then
    print -u2 'The regression guard accepted the historical backwards build number.'
    exit 1
fi

if lima_release_build_number 3.1000.0 >/dev/null 2>&1; then
    print -u2 'The build-number policy accepted a four-digit minor component.'
    exit 1
fi

print 'Release versioning regression tests passed.'
