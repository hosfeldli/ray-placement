# Lima release procedure

This document is the canonical procedure for building and distributing Lima. The
release lifecycle is deliberately split into small, resumable phases. A build,
upload, draft review, and publication are separate operations.

The current distribution uses Lima's pinned local self-signed certificate. It is
not an Apple-notarized Developer ID distribution, and this repository does not
support Developer ID or Apple Developer Program signing variables. macOS may
require **Control-click → Open** the first time the app is installed. The custom
updater trusts the same stable certificate across releases; Sparkle migration is
a separate future project.

## Safety rules

* `release_prepare.sh` is the only release script that changes version metadata.
* Build, stage, verify, and publish scripts do not commit, push, tag, or rewrite
    source files. Tagging is an explicit operation handled only by
    `release_tag.sh`.
* `release_stage.sh` creates or resumes **draft** releases only.
* Bridge-enabled releases require a source-matching Mozilla-signed companion XPI
    via `LIMA_BROWSER_BRIDGE_SIGNED_XPI`; preserve the downloaded signed bytes.
    `release_build.sh` rejects a missing/invalid artifact, computes its digest, and
    verifies it inside the built app/DMG. Future companion updates use a newly
    approved XPI and a new app version/tag; never replace a published release.
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

A routine **hosted** deployment needs only a clean, synchronized repository plus
`gh`, authenticated to `hosfeldli/ray-placement` with permission to push the
version commit/tag and dispatch the release workflow. It does not need a local
signing keychain, P12, Sparkle key, `gcloud`, a full DMG, or local build caches.

Xcode Command Line Tools/Swift 6, `make`, `jq`, `python3`, `openssl`, `shasum`,
`hdiutil`, `codesign`, `security`, `split`, `rsync`, free disk space, and local
signing material are required only for local development, rehearsal, or recovery
phases. Run `gh auth status` before dispatching. Hosted preflight checks the
immutable tag, source identity, signing policy, release state, and cloud inputs.

## Signing configuration

All packaging and release phases source `scripts/release_config.sh`. The
self-signed local defaults are:

| Setting | Default |
|---|---|
| Signing mode | `self-signed-local` |
| Identity | `RayPlacement Local Code Signing` |
| Certificate SHA-256 | `3dfe6a7f48bff98946a3b309f733c58b515d026daca0cfe63bf03f6a09142f12` |
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
and the actual certificate match the pinned SHA-256 fingerprint. The identity and
fingerprint are public policy, not credentials; never rotate the certificate
without intentionally changing the updater trust anchor for existing installs.

### Hosted release signing

GitHub Actions obtains short-lived GCP credentials through GitHub OIDC, then the
`lima-release` service account reads the signing inputs from Secret Manager. The
routine release workflow does **not** use GitHub repository signing secrets or a
service-account JSON key:

| Secret Manager secret | Contents |
|---|---|
| `lima-signing-p12` | Raw PKCS #12 bundle containing the `RayPlacement Local Code Signing` certificate and private key |
| `lima-signing-p12-password` | Password protecting the PKCS #12 bundle |
| `lima-sparkle-private-key` | Sparkle private key used only by the packaging step |

The workflow writes these only to the disposable GitHub macOS runner, creates a
temporary keychain, verifies the pinned identity, and removes the keychain,
signing directory, Sparkle key file, and temporary credentials in its always-run
cleanup. Do not copy these materials to a development Mac for routine releases.

Do not create secrets for the signing identity, certificate fingerprint, Team ID,
serialized keychains, or a separate public certificate. The identity and
fingerprint are source-controlled policy, and the public certificate is already
inside the P12 bundle. There is no supported Developer ID signing override.

Other supported overrides are `RAYPLACEMENT_SIGNING_DIRECTORY`,
`RAYPLACEMENT_SIGNING_KEYCHAIN`, `RAYPLACEMENT_SIGNING_PASSWORD_FILE`,
`RAYPLACEMENT_SIGNING_CERTIFICATE`, `RAYPLACEMENT_DMG_PART_SIZE`,
`RAYPLACEMENT_DMG_PART_SUFFIX_LENGTH`, `RAYPLACEMENT_MINIMUM_FREE_KB`, and
`RAYPLACEMENT_MAX_UPDATE_BYTES`.

Do not pass a stale certificate fingerprint. The same policy is embedded in the
app, used by the local verifier, and recorded in `dist/Lima-release.json`.

### Signing trust-anchor rotation

On 2026-09-10 the signing certificate was intentionally rotated. The previous
SHA-256 fingerprint was `ade4836267093fbf4b18658d6aad3bdac25cbf162e022ca7bdf89f4898f3d4da`; the active fingerprint is `3dfe6a7f48bff98946a3b309f733c58b515d026daca0cfe63bf03f6a09142f12`.
Existing installations signed with the previous certificate may not accept a
newly signed application through the legacy updater. Treat the first release
after this rotation as a migration release: validate a manual installation
or an explicitly implemented dual-trust path before claiming seamless updates.
The pre-rotation local materials are retained under the dated rollback backup.

## Recommended hosted deployment

Use this path for every normal Lima release. The Mac prepares and tags source;
the hosted workflow builds, signs, verifies, archives, stages, and—when selected—
publishes. Do not run a local release build or copy signing material locally.

1. Commit and push the completed release work to `main`. Confirm its default-branch
   CI run is green and the source tree is clean.
2. Prepare and push the next version. Note the printed version (for example,
   `3.14.5`):

   ```sh
   ./scripts/release_prepare.sh --bump patch --commit --push
   ```

3. Wait for CI on that version commit to pass, then create the immutable annotated
   tag:

   ```sh
   ./scripts/release_tag.sh --version 3.14.5 --push
   ```

4. In GitHub, open **Actions → Build and stage Lima release → Run workflow**.
   Choose `main`, enter `v3.14.5` as **release_tag**, and enable **publish** only
   when this run is intended to become public. Start the workflow, then approve
   the pending `release` environment deployment.
5. Wait for every workflow step to succeed. With **publish** enabled, the same
   run makes the verified draft public. Confirm the release page contains the
   DMG, updater and Sparkle ZIPs, their checksums, `Lima-release.json`,
   `latest.json`, and `appcast.xml`.

The equivalent command-line dispatch is:

```sh
gh workflow run release-update.yml --repo hosfeldli/ray-placement --ref main \
  -f release_tag=v3.14.5 -f publish=true
```

Approve the `release` environment in GitHub when it pauses, then monitor the run
from Actions or with `gh run watch RUN_ID --repo hosfeldli/ray-placement --exit-status`.
A run with `publish=false` deliberately stops at a verified draft; use it only for
a planned review or rehearsal, not as a shortcut around the release checks.

Never change an existing release tag or replace published assets. If a hosted run
fails, preserve its tag and logs, fix the source on `main`, obtain green CI, and
issue a new version/tag. See [Build assets and recovery](#build-assets-and-recovery)
for a staging-recovery case where verified bytes already exist in private GCS.

## Local / legacy fast paths

The dispatcher remains available for local rehearsal or recovery only. It does
not bypass source identity, signing, asset digest, or draft-verification checks.

```sh
# Create, build, stage, and verify the next patch as a GitHub draft locally.
LIMA_BROWSER_BRIDGE_SIGNED_XPI="$HOME/Downloads/Lima Browser Bridge 1.1.0.xpi" \
    ./scripts/release.sh ship --bump patch

# Inspect the next version without changing the working tree or GitHub.
./scripts/release.sh ship --bump patch --dry-run
```

`ship` commits and pushes version metadata, creates and pushes the immutable tag,
then runs a local build, draft staging, and verification. It is not the routine
production deployment path; use the hosted workflow above instead.

## Local diagnosis and recovery

Normal production releases use the hosted workflow above. The individual scripts
remain available to inspect a tagged release or recover an interrupted draft; they
are not an alternate production deployment path.

Use the exact immutable tag—never an untagged commit or a published release—and
run only the phase required by the incident:

```sh
./scripts/release_preflight.sh --tag vX.Y.Z
./scripts/release_verify.sh --tag vX.Y.Z --remote-only
```

If a hosted build completed and its private archive exists but GitHub draft staging
did not, follow [Build assets and recovery](#build-assets-and-recovery) to restore
verified bytes and resume staging. If a hosted build fails before archival, retain
its logs and immutable tag,
fix source on main, wait for green CI, and release a new version/tag. Do not rebuild,
restage, or publish a failed tag from a development Mac as a routine workaround.

Local signing and local release_build.sh, release_stage.sh, and release_publish.sh
commands are reserved for an explicitly planned recovery or rehearsal. They require
the documented local tooling and must preserve the same tag, digest, draft-only, and
explicit-publication checks. Never use them to overwrite a published release or
replace a cloud-built artifact.

## Script reference

| Script | Purpose | May modify Git/source? | May contact GitHub? |
|---|---|---:|---:|
| `release_config.sh` | Shared signing, artifact, and size policy | No | No |
| `release_common.sh` | Shared metadata, digest, and draft helpers | No | Read/write helpers only when called |
| `release_prepare.sh` | Explicit version preparation | Source only; commit/push only when requested | Push only when requested |
| `release_tag.sh` | Immutable annotated tag creation | Git tag only; push only when requested | Push only when requested |
| `release_preflight.sh` | Read-only release gate | No | Read only |
| `release_build.sh` | Signed artifact build; hosted workflow or explicit local recovery | No | Read only through preflight |
| `release_stage.sh` | Draft creation, idempotent upload, and multipart assembly | No | Draft/assets/workflow only |
| `release_verify.sh` | Local or remote digest/signing verification | No | Read only |
| `release_publish.sh` | Promote a verified draft to public | No | Publish only with `--yes` |
| `release_resume.sh` | Resume staging and verify an existing draft | No | Draft/assets/workflow only |
| `release.sh` | Local compatibility dispatcher; not the routine production path | No | Delegates to phase |
| `deploy_lima.sh` | Backward-compatible local wrapper; not the routine production path | No | Delegates to phase |

## Website deployment boundary

The portfolio site and the Lima app release are separate systems. The community
extension submission quarantine, store catalog, and website archive directories
are not part of this release lifecycle. Do not stage or modify website
`archive/` directories while releasing the app. Deploy website changes through
the website repository's own CI process and verify its live endpoints separately.

## Immutable release identity and update metadata

Immutable version tags are the source of truth for release artifacts. Every
release build, CI workflow, DMG assembly job, and verification phase must resolve
and build the exact commit referenced by its `vX.Y.Z` tag. Branches, including
release-named branches, are never release artifact identities.

The staged release assets include:

```text
dist/Lima-release.json
dist/latest.json
dist/appcast.xml
```

`latest.json` is the active updater's stable feed. It is generated from the same
metadata as the update archive and includes the release tag, commit, version,
archive URL, archive size, and SHA-256 digest. The release scripts validate its
schema and content locally and again after downloading the published assets.

`appcast.xml` is a migration-only Sparkle 2 artifact. It intentionally carries
`lima:signatureStatus="pending-sparkle-signature"` and must not be treated as a
production Sparkle feed until a real N→N+1 installation test passes with a
properly signed Sparkle archive. Lima's active updater remains the signed custom
updater; the optional Sparkle package graph is only enabled with:

```sh
LIMA_ENABLE_SPARKLE_MIGRATION=1 swift package dump-package
```

The default package graph does not fetch or resolve Sparkle. The offline graph
check is:

```sh
./scripts/test_sparkle_migration.sh
```

Feed and appcast assets are generated during the hosted build, uploaded during
draft staging, included in remote digest verification, and required before
publication. They are not optional release documentation.

## Continuous integration gates

The pull-request and branch workflow runs:

* all Swift tests with `make test`;
* Zsh syntax checks for every shell script;
* release metadata/feed/appcast tests;
* updater fault-injection tests;
* conditional Sparkle package-graph validation; and
* a debug package smoke build plus plist and package-resolution checks.

The CI workflow does not sign, upload, stage, or publish a release.

## Hosted GCP release environment

Routine release builds run on the manual **Build and stage Lima release** workflow,
not on a developer Mac. The workflow checks out the immutable annotated tag on an
ephemeral GitHub macOS runner, authenticates to GCP through GitHub OIDC, retrieves
only its temporary release inputs, and runs the existing release scripts in order:

```text
prepare verified build assets
→ prepare temporary Keychain and Sparkle key file
→ release_preflight.sh
→ release_build.sh
→ archive_release_to_gcs.sh
→ release_stage.sh
→ release_verify.sh --remote-only
```

It stages a verified draft by default. The manual dispatch has a default-off
**publish** option; selecting it invokes the same
`release_publish.sh --tag vX.Y.Z --yes` step on that ephemeral runner only after
draft verification succeeds. Leaving it off keeps the draft for separate review.

GitHub’s temporary `gha-creds-*.json` file and the GCS-delivered signed companion
path are ignored as runner material, not source. The companion’s repository-tracked
asset manifest still pins its destination and SHA-256, and
`prepare_build_assets.sh` verifies it before packaging.

### Persistent cloud resources

The isolated project is `lima-build-prod`. It contains the private build-input
bucket `lima-build-assets-940267100054`, private archive bucket
`lima-release-archive-940267100054`, and three Secret Manager secrets:
`lima-signing-p12`, `lima-signing-p12-password`, and
`lima-sparkle-private-key`. Neither bucket is a public distribution endpoint;
GitHub Releases remains the sole public artifact and updater source.

The GitHub OIDC provider is limited to the immutable repository ID `1342815274`
and owner ID `43440666`. It has no service-account JSON key. `lima-ci` is
reserved for read-only build assets; `lima-release` is the only release principal
and receives secret access only to the three named secrets plus read/create access
to the private archive. The pinned signing identity and certificate SHA-256 remain
source-controlled policy in `release_config.sh`.

An IAM administrator completes or reapplies those narrow bindings with:

```sh
./scripts/provision_gcp_release_iam.sh lima-build-prod 940267100054
```

This is intentionally separate from normal release operations. It creates no
secrets and grants no project-wide Owner, Editor, or service-account-key access.

### Build assets and recovery

`Packaging/build-assets.json` pins the GCS object name, installation location,
SHA-256, and mode for the Whisper model, Harper binary, and Mozilla-signed Browser
Bridge XPI. `prepare_build_assets.sh` verifies every materialized input before
packaging; Whisper retains its verified installed/upstream fallback for local
development. Harper remains in Git LFS pending a separate, history-aware cleanup;
that does not change the hosted asset-verification contract.

After a verified build, artifacts are archived before draft staging under both
`builds/<commit>/` and `releases/<version>/`. Existing remote bytes must match
exactly; archive collisions are refused. A failed stage can be recovered on the
matching checked-out tag without rebuilding:

```sh
LIMA_RELEASE_ARCHIVE_BUCKET=lima-release-archive-940267100054 \
  ./scripts/restore_release_from_gcs.sh --tag vX.Y.Z --replace
./scripts/release_stage.sh --tag vX.Y.Z
```

The restore command rechecks all archive sidecars, metadata digest fields, tag
identity, stable feed, and signed appcast before placing bytes in `dist/`.

### Developer and migration boundaries

Local `make test` and developer builds remain supported. Normal CI stays unsigned
and has neither GCP authentication nor release-secret access. The release workflow
uses GitHub OIDC, GCP Secret Manager, and `gcloud storage`; it has no GitHub signing
secret or service-account-key path. Do not substitute `gsutil` in the workflow,
because its authentication behavior differs from the exported OIDC credentials.

Run the offline integration check with:

```sh
./scripts/test_cloud_release_configuration.sh
```

It validates the workflow contract, manifest digests, and cloud-neutral signing
variables without authenticating to GCP or retrieving a secret.
