# Lima release procedure

This document is the canonical procedure for building and distributing Lima. The
release lifecycle is deliberately split into small, resumable phases. A build,
upload, draft review, and publication are separate operations.

The current distribution uses Lima's pinned local self-signed certificate. It is
not an Apple-notarized Developer ID distribution. macOS may require **Control-
click → Open** the first time the app is installed. Developer ID is supported
only as an explicit, fully configured alternate signing policy.

## Safety rules

* `release_prepare.sh` is the only release script that changes version metadata.
* Build, stage, verify, and publish scripts do not commit, push, tag, or rewrite
    source files.
* `release_stage.sh` creates or resumes **draft** releases only.
* Published releases are never overwritten by the release scripts.
* `release_publish.sh` is the only publication step and requires `--yes`.
    Publication is public and should be treated as irreversible.
* The website repository is a separate deployment. App release commands do not
    modify or deploy the portfolio site.
* `dist/`, `build/`, and `.release-work/` are local/ignored release artifacts;
    do not commit them.

## Prerequisites

Run these commands from the app repository:

```sh
cd /Users/liamhosfeld/Documents/Codex/2026-08-21/make/work/ray-placement
```

Required tools include:

* Xcode Command Line Tools/Swift 6, `make`, and the macOS packaging tools;
* `gh`, authenticated to `hosfeldli/ray-placement` with permission to create
    draft releases, upload assets, and dispatch the DMG assembly workflow;
* `jq`, `openssl`, `shasum`, `hdiutil`, `codesign`, `security`, `split`, and
    `rsync`;
* enough free disk space for a full DMG and temporary build resources.

Run `gh auth status` before starting. The preflight also checks authentication,
branch synchronization, the signing policy, certificate fingerprint, disk space,
release state, and required commands.

## Signing configuration

All packaging and release phases source `scripts/release_config.sh`. The
self-signed local defaults are:

| Setting | Default |
|---|---|
| Signing mode | `self-signed-local` |
| Identity | `RayPlacement Local Code Signing` |
| Team identifier | `not set` |
| Certificate SHA-256 | `ade4836267093fbf4b18658d6aad3bdac25cbf162e022ca7bdf89f4898f3d4da` |
| DMG part size | `24m` |
| DMG part suffix length | `2` |
| Minimum free space | `5242880` KiB |
| Maximum update archive | `104857600` bytes |

Local signing files normally reside at:

```text
~/Library/Application Support/RayPlacement/Signing/
├── RayPlacementSigning.keychain-db
├── keychain-password
└── RayPlacementLocalSigning.cer
```

Use `scripts/setup_local_signing.sh` to install or repair the local signing
identity when necessary. `release_preflight.sh` checks that the keychain identity
and the actual certificate match the pinned SHA-256 fingerprint.

Environment overrides are intended for CI or an explicit alternate policy:

```sh
RAYPLACEMENT_SIGNING_MODE=developer-id
RAYPLACEMENT_EXPECTED_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
RAYPLACEMENT_EXPECTED_TEAM_IDENTIFIER='TEAMID'
RAYPLACEMENT_EXPECTED_CERTIFICATE_SHA256='...64 hexadecimal characters...'
```

Other supported overrides are `RAYPLACEMENT_SIGNING_DIRECTORY`,
`RAYPLACEMENT_SIGNING_KEYCHAIN`, `RAYPLACEMENT_SIGNING_PASSWORD_FILE`,
`RAYPLACEMENT_SIGNING_CERTIFICATE`, `RAYPLACEMENT_DMG_PART_SIZE`,
`RAYPLACEMENT_DMG_PART_SUFFIX_LENGTH`, `RAYPLACEMENT_MINIMUM_FREE_KB`, and
`RAYPLACEMENT_MAX_UPDATE_BYTES`.

Do not pass a stale certificate fingerprint. The same policy is embedded in the
app, used by the local verifier, and recorded in `dist/Lima-release.json`.

## Normal release lifecycle

### 1. Prepare the version

Preparation refuses a dirty source tree by default and updates the authoritative
`Packaging/Info.plist` version/build pair. It also updates the README heading and
distribution note when those expected references are present. README text is
informational; `scripts/check_release_consistency.sh` gates only the plist.

For a normal patch release:

```sh
./scripts/release_prepare.sh --bump patch --commit --push
```

Or set the version explicitly:

```sh
./scripts/release_prepare.sh --version 3.13.0 --commit --push
```

To inspect the calculated version without changing anything:

```sh
./scripts/release_prepare.sh --bump patch --dry-run
```

The default is `--no-commit --no-push`. Use `--allow-dirty` only when the
unrelated changes are intentional and will not be included in the release.

### 2. Run the read-only preflight

```sh
./scripts/release_preflight.sh --tag v3.12.6
```

Preflight requires a clean worktree and a branch whose upstream has the exact
same commit. It refuses an existing published release. An existing draft for the
same tag is resumable.

### 3. Build locally

```sh
LIMA_RELEASE_SKIP_PREFLIGHT=1 ./scripts/release_build.sh --tag v3.12.6
```

This phase runs:

* `make test`;
* `scripts/test_lima_installer.sh`;
* `scripts/test_update_verifier.sh`;
* `scripts/test_approved_lima_update.sh`;
* a model-free, signed app build for `Lima-Update.zip`;
* a full signed app/DMG build for `Lima.dmg`;
* local app, DMG, archive, and checksum verification.

It writes these ignored artifacts:

```text
dist/Lima-Update.zip
dist/Lima-Update.sha256
dist/Lima.dmg
dist/Lima.dmg.sha256
dist/Lima-release.json
```

A complete, checksum-matching build can be reused after an interrupted later
phase:

```sh
./scripts/release_build.sh --tag v3.12.6 --reuse
```

`--reuse` still runs local artifact verification but does not silently accept a
missing, differently tagged, or checksum-mismatched build.

### 4. Stage a draft

```sh
./scripts/release_stage.sh --tag v3.12.6
```

The stage phase creates a draft if one does not exist, or resumes the existing
draft. It uploads the update archive and checksum assets idempotently. It never
uploads a full DMG directly.

The DMG is split using the shared part size and suffix policy, normally into
parts such as:

```text
Lima.dmg.part-aa
Lima.dmg.part-ab
...
```

Each part is uploaded only when it is missing or its GitHub API digest does not
match the local part. The script then dispatches
`.github/workflows/assemble-signed-dmg.yml` with the exact local DMG SHA-256 and
part count. The workflow:

1. confirms the release is still a draft;
2. downloads and orders all parts;
3. reassembles and checks the exact SHA-256;
4. uploads `Lima.dmg`;
5. checks the GitHub asset digest;
6. deletes only the temporary part assets;
7. leaves the release as a draft.

A dry-run shows the intended upload strategy without contacting GitHub:

```sh
./scripts/release_stage.sh --tag v3.12.6 --dry-run
```

### 5. Verify before publishing

```sh
./scripts/release_verify.sh --tag v3.12.6
```

Verification checks local checksums and signing, then checks the draft's exact
update and DMG assets. Remote SHA-256 values are obtained from each asset's
lower-level GitHub API `digest` field, not from the unreliable digest value
returned by some `gh release view` responses. Verification also refuses to pass
while any `Lima.dmg.part-*` temporary asset remains.

A remote-only check is useful after a workflow finishes or from another machine:

```sh
./scripts/release_verify.sh --tag v3.12.6 --remote-only
```

Published releases may be verified read-only, but no release script will mutate
them.

### 6. Publish only after review

The final action is intentionally explicit:

```sh
./scripts/release_publish.sh --tag v3.12.6 --yes
```

The script requires a clean tree, a draft release, matching source/tag metadata,
and a successful verification. It only changes the GitHub draft to public and
prints the final release URL. It does not rebuild or upload anything.

The dispatcher provides the same lifecycle:

```sh
./scripts/release.sh preflight --tag v3.12.6
./scripts/release.sh build --tag v3.12.6
./scripts/release.sh stage --tag v3.12.6
./scripts/release.sh verify --tag v3.12.6
./scripts/release.sh publish --tag v3.12.6 --yes
```

The compatibility command is now staged rather than monolithic:

```sh
./scripts/deploy_lima.sh --tag v3.12.6
./scripts/deploy_lima.sh --tag v3.12.6 --publish --yes
```

The first command remains draft-only. The second is equivalent to running all
phases followed by explicit publication.

## Resume and recovery

Interrupted release work should be resumed, not restarted blindly.

```sh
./scripts/release_resume.sh --tag v3.12.6
```

This resumes multipart staging and then verifies the draft without rebuilding or
publishing. The individual phases are safe to rerun as well:

* interrupted local builds: rerun `release_build.sh`, or use `--reuse` when all
    checksummed artifacts are complete;
* interrupted update upload: rerun `release_stage.sh`; verified assets are
    skipped;
* interrupted DMG split/upload: rerun `release_stage.sh`; local parts are reused
    when present, and remote parts are checked by digest;
* interrupted assembly workflow: rerun `release_stage.sh`; if `Lima.dmg` is not
    present, the workflow can be dispatched again;
* failed verification: inspect the reported asset/digest and rerun stage only
    after correcting the local artifact or draft asset.

### Cleaning stale draft assets

Do not delete assets from a published release. For a draft, inspect first:

```sh
gh release view v3.12.6 --json isDraft,assets
```

Temporary part assets may be removed from a draft when a failed workflow has left
them behind:

```sh
gh release delete-asset v3.12.6 Lima.dmg.part-aa --yes
gh release delete-asset v3.12.6 Lima.dmg.part-ab --yes
```

Then rerun `release_stage.sh`. The normal assembly workflow removes its own parts
only after the reconstructed DMG has passed its digest check.

If the draft contains an artifact from the wrong source commit or version, stop
and create a new version/tag rather than trying to mutate a release that may have
been reviewed. Published releases are never repaired in place.

## Rehearsal with a patch increment

The safe rehearsal requested for this refactor is a path/patch increment from
`3.12.5` to `3.12.6`. It must not publish `v3.12.6`.

Run the static checks first:

```sh
for f in scripts/release_*.sh scripts/check_release_consistency.sh scripts/deploy_lima.sh; do
    /bin/zsh -n "$f"
done
./scripts/check_release_consistency.sh
./scripts/release.sh --help
```

Then prepare without a commit or push:

```sh
./scripts/release_prepare.sh --version 3.12.6 --no-commit --rehearsal
```

Confirm the plist reports version `3.12.6` and build `3126`, then run the tests
and local phases. Preflight requires a pushed commit, so an uncommitted rehearsal
can use the test commands directly; a full preflight/build rehearsal requires
committing and pushing the version intentionally, or using a disposable branch.

For a source tree containing the release refactor itself, `--rehearsal` permits
the intentional refactor changes while still refusing to overwrite the version
without an explicit preparation command. A fully clean disposable branch should
continue to use the stricter command without `--rehearsal`.

At minimum:

```sh
./scripts/check_release_consistency.sh
make test
./scripts/test_lima_installer.sh
./scripts/test_update_verifier.sh
/bin/zsh scripts/test_approved_lima_update.sh
```

A full local artifact build is:

```sh
./scripts/release_build.sh --tag v3.12.6
```

For a dirty refactor worktree that has not yet been committed/pushed, the same
local build can be rehearsed explicitly with:

```sh
LIMA_RELEASE_SKIP_PREFLIGHT=1 ./scripts/release_build.sh --tag v3.12.6
```

Do **not** run `release_publish.sh --yes` for this rehearsal. If the change is
not intended to become the next source version, restore `Packaging/Info.plist`
and the README references to `3.12.5`, then run the consistency check and review
`git diff --check`. If it is intended to become the next release, commit and push
it, but still leave the GitHub release as a draft or do not stage it at all.

## Script reference

| Script | Purpose | May modify Git/source? | May contact GitHub? |
|---|---|---:|---:|
| `release_config.sh` | Shared signing, artifact, and size policy | No | No |
| `release_common.sh` | Shared metadata, digest, and draft helpers | No | Read/write helpers only when called |
| `release_prepare.sh` | Explicit version preparation | Source only; commit/push only when requested | Push only when requested |
| `release_preflight.sh` | Read-only release gate | No | Read only |
| `release_build.sh` | Tests, signed artifacts, local metadata | No | Read only through preflight |
| `release_stage.sh` | Draft creation, idempotent upload, multipart assembly | No | Draft/assets/workflow only |
| `release_verify.sh` | Local and remote digest/signing verification | No | Read only |
| `release_publish.sh` | Promote verified draft to public | No | Publish only with `--yes` |
| `release_resume.sh` | Stage and verify an existing draft | No | Draft/assets/workflow only |
| `release.sh` | Command dispatcher/orchestrator | No | Delegates to phase |
| `deploy_lima.sh` | Backward-compatible staged wrapper | No | Delegates to phase |

## Website deployment boundary

The portfolio site and the Lima app release are separate systems. The community
extension submission quarantine, store catalog, and website archive directories
are not part of this release lifecycle. Do not stage or modify website
`archive/` directories while releasing the app. Deploy website changes through
the website repository's own CI process and verify its live endpoints separately.
