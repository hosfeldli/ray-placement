#!/bin/zsh
set -euo pipefail

CURRENT_USER="$(id -un)"
USER_HOME_DIRECTORY="$(dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory | awk '{print $2}')"
SIGNING_DIRECTORY="$USER_HOME_DIRECTORY/Library/Application Support/RayPlacement/Signing"
KEYCHAIN_PATH="$SIGNING_DIRECTORY/RayPlacementSigning.keychain-db"
PASSWORD_PATH="$SIGNING_DIRECTORY/keychain-password"
CERTIFICATE_PATH="$SIGNING_DIRECTORY/RayPlacementLocalSigning.cer"
LOGIN_KEYCHAIN_PATH="$USER_HOME_DIRECTORY/Library/Keychains/login.keychain-db"
IDENTITY_NAME="RayPlacement Local Code Signing"

if [[ -z "$USER_HOME_DIRECTORY" || "$USER_HOME_DIRECTORY" != /Users/* ]]; then
    echo "Could not safely locate the current user's home folder."
    exit 1
fi

mkdir -p "$SIGNING_DIRECTORY"
chmod 700 "$SIGNING_DIRECTORY"
umask 077

if [[ -f "$KEYCHAIN_PATH" && -f "$PASSWORD_PATH" ]]; then
    KEYCHAIN_PASSWORD="$(<"$PASSWORD_PATH")"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    if security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -q "\"$IDENTITY_NAME\""; then
        echo "RayPlacement local signing identity is ready."
        echo "Keychain: $KEYCHAIN_PATH"
        exit 0
    fi
    if [[ -f "$CERTIFICATE_PATH" ]]; then
        security add-trusted-cert \
            -r trustRoot \
            -p codeSign \
            -k "$LOGIN_KEYCHAIN_PATH" \
            "$CERTIFICATE_PATH"
        if security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -q "\"$IDENTITY_NAME\""; then
            echo "RayPlacement local signing identity is ready."
            echo "Private keychain: $KEYCHAIN_PATH"
            exit 0
        fi
    fi
    echo "The RayPlacement signing keychain exists but its identity is unavailable."
    echo "Move $SIGNING_DIRECTORY aside, then run this setup again."
    exit 1
fi

TEMP_DIRECTORY="$(mktemp -d "${TMPDIR%/}/rayplacement-signing.XXXXXX")"
cleanup() {
    [[ "$TEMP_DIRECTORY" == "${TMPDIR%/}"/rayplacement-signing.* ]] && rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
printf '%s\n' "$KEYCHAIN_PASSWORD" > "$PASSWORD_PATH"
chmod 600 "$PASSWORD_PATH"

openssl req \
    -new -newkey rsa:2048 -x509 -sha256 -days 3650 -nodes \
    -subj "/CN=$IDENTITY_NAME/O=RayPlacement Local Development" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$TEMP_DIRECTORY/private-key.pem" \
    -out "$TEMP_DIRECTORY/certificate.pem"

openssl x509 -in "$TEMP_DIRECTORY/certificate.pem" -outform der -out "$CERTIFICATE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" \
    -k "$KEYCHAIN_PATH"
security import "$TEMP_DIRECTORY/private-key.pem" \
    -k "$KEYCHAIN_PATH" \
    -P "" \
    -T /usr/bin/codesign
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$LOGIN_KEYCHAIN_PATH" \
    "$CERTIFICATE_PATH"

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -q "\"$IDENTITY_NAME\""; then
    echo "The local signing identity was created but macOS did not accept it for code signing."
    exit 1
fi

echo "Created a local-only RayPlacement signing identity."
echo "Private keychain: $KEYCHAIN_PATH"
echo "The public certificate is trusted for code signing in the login keychain."
echo "It is used only to keep macOS Accessibility approval stable between local builds."
