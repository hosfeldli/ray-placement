# Lima release signing

## Sparkle update-signing key

The Sparkle EdDSA signing key is stored in the macOS **login Keychain** and is
managed by Sparkle's `generate_keys` tool.

* Sparkle account: `lima-sparkle`
* Keychain: the current user's `login` keychain
* Keychain Access search: `Private key for signing Sparkle updates`
* Sparkle lookup command:

    `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account lima-sparkle -p`

The private key must never be committed to Git, printed in a terminal, pasted
into chat, or stored in this repository. The GitHub Actions repository secret
`SPARKLE_EDDSA_PRIVATE_KEY` contains a protected export of this same key for
release automation.

If the key must be transferred to another machine, use Sparkle's export/import
options only through a protected temporary file, then remove the file after the
import. Verify that the public key reported by Sparkle matches the
`SUPublicEDKey` value in `Packaging/Info.plist`.

Current public key:

`fyOhQjqcI/f18TiRvtKyCSD5PM8RHUZtitjnZKLs+08=`

## Code-signing key

The macOS application certificate is separate from the Sparkle key. Its local
keychain material lives under:

`~/Library/Application Support/RayPlacement/Signing/`

The `keychain-password` file in that directory unlocks the local code-signing
keychain; it is not the Sparkle signing key.
