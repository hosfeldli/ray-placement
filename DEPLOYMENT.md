# Lima deployment workspace

This is a clean deployment copy of the Lima project. Generated build output,
release artifacts, Git metadata, local downloads, and obsolete RayPlacement
installer/uninstaller launchers were intentionally excluded.

## Deploy a release

From this directory:

```zsh
./scripts/deploy_lima.sh --tag vX.Y.Z
```

The command runs tests, builds both signed artifacts, uploads them to a draft
GitHub release, and verifies GitHub's stored SHA-256 digests. To publish after
verification:

```zsh
./scripts/deploy_lima.sh --tag vX.Y.Z --publish
```

The script refuses to overwrite an already-published release. The local
private signing key remains in the user's Application Support keychain and is
never copied into this workspace or uploaded.
