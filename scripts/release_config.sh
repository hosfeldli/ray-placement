#!/bin/zsh
# Shared Lima release configuration and policy helpers.
#
# This file is sourced by packaging and release scripts. It is intentionally
# free of side effects: it does not create keychains, modify Git, or contact
# GitHub. The signing identity and certificate fingerprint are fixed public
# policy; CI supplies only the private key through its temporary keychain.

# Lima currently uses one stable local certificate for both application
# signing and custom-updater trust. The identity and public fingerprint are
# policy, not credentials; only the private key material must be provisioned.
LIMA_RELEASE_SIGNING_MODE="self-signed-local"
LIMA_RELEASE_SIGNING_IDENTITY="RayPlacement Local Code Signing"
LIMA_RELEASE_CERTIFICATE_SHA256="3dfe6a7f48bff98946a3b309f733c58b515d026daca0cfe63bf03f6a09142f12"
# Existing installations may still trust the preceding certificate; this is a deliberate trust-anchor rotation.
LIMA_RELEASE_DMG_PART_SIZE="${RAYPLACEMENT_DMG_PART_SIZE:-24m}"
LIMA_RELEASE_DMG_PART_SUFFIX_LENGTH="${RAYPLACEMENT_DMG_PART_SUFFIX_LENGTH:-2}"
LIMA_RELEASE_MINIMUM_FREE_KB="${RAYPLACEMENT_MINIMUM_FREE_KB:-5242880}"
LIMA_RELEASE_MAX_UPDATE_BYTES="${RAYPLACEMENT_MAX_UPDATE_BYTES:-104857600}"
LIMA_RELEASE_LOCAL_SIGNING_DIRECTORY="${RAYPLACEMENT_SIGNING_DIRECTORY:-$HOME/Library/Application Support/RayPlacement/Signing}"
LIMA_RELEASE_LOCAL_SIGNING_KEYCHAIN="${RAYPLACEMENT_SIGNING_KEYCHAIN:-$LIMA_RELEASE_LOCAL_SIGNING_DIRECTORY/RayPlacementSigning.keychain-db}"
LIMA_RELEASE_LOCAL_SIGNING_PASSWORD="${RAYPLACEMENT_SIGNING_PASSWORD_FILE:-$LIMA_RELEASE_LOCAL_SIGNING_DIRECTORY/keychain-password}"
LIMA_RELEASE_LOCAL_SIGNING_CERTIFICATE="${RAYPLACEMENT_SIGNING_CERTIFICATE:-$LIMA_RELEASE_LOCAL_SIGNING_DIRECTORY/RayPlacementLocalSigning.cer}"

lima_release_export_packaging_policy() {
    export RAYPLACEMENT_SIGNING_MODE="$LIMA_RELEASE_SIGNING_MODE"
    export RAYPLACEMENT_SIGNING_IDENTITY="$LIMA_RELEASE_SIGNING_IDENTITY"
    export RAYPLACEMENT_EXPECTED_SIGNING_IDENTITY="$LIMA_RELEASE_SIGNING_IDENTITY"
    export RAYPLACEMENT_EXPECTED_CERTIFICATE_SHA256="$LIMA_RELEASE_CERTIFICATE_SHA256"
}

lima_release_validate_signing_policy() {
    [[ "$LIMA_RELEASE_SIGNING_MODE" == "self-signed-local" ]] || {
        print -u2 "Only the self-signed-local release policy is supported."
        return 1
    }
    [[ "$LIMA_RELEASE_SIGNING_IDENTITY" == "RayPlacement Local Code Signing" ]] || {
        print -u2 "The release identity must be RayPlacement Local Code Signing."
        return 1
    }
    [[ "$LIMA_RELEASE_CERTIFICATE_SHA256" =~ '^[[:xdigit:]]{64}$' ]] || {
        print -u2 "The release certificate fingerprint must be 64 hexadecimal characters."
        return 1
    }
    [[ "$LIMA_RELEASE_DMG_PART_SUFFIX_LENGTH" == 2 ]] || {
        print -u2 "DMG part suffix length must be exactly 2 for the GitHub assembly workflow."
        return 1
    }
    [[ "$LIMA_RELEASE_MINIMUM_FREE_KB" =~ '^[0-9]+$' ]] || {
        print -u2 "Minimum free disk space must be an integer number of KiB."
        return 1
    }
}

lima_release_validate_version() {
    local version="$1"
    [[ "$version" =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)$' ]] || {
        print -u2 "Invalid Lima version: $version (expected X.Y.Z)."
        return 1
    }
}

lima_release_build_number() {
    local version="$1"
    lima_release_validate_version "$version"
    print -r -- "${version//./}"
}

lima_release_version_from_plist() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist"
}

lima_release_build_from_plist() {
    local plist="$1"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"
}
