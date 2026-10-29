# Lima major-release migration and acceptance status

This document describes the in-progress simplification release. It is **not a publication approval**. The Mail-send and real-device gates below remain open.

## Retired Workflows data

The former dedicated Workflows product stored user definitions in `~/Library/Application Support/Lima/workflows.json` (or the migrated legacy RayPlacement application-support root). The file is a JSON array of legacy `WorkflowDefinition` records. Lima retains that Codable schema only to identify old definitions; it does not execute them.

At launch, `LegacyWorkflowArchive` makes an inactive, byte-for-byte snapshot in `Archived Workflows/workflows-<timestamp>-<UUID>.json`. It preserves the original source, previous snapshots, and even malformed nonempty bytes. A matching snapshot is not duplicated on each launch. The archive uses private directory/file permissions. Settings → Advanced → Privacy provides Reveal, Export, and a separately confirmed cleanup option when saved definitions exist. Cleanup is never part of launch migration.

The dedicated editor, command catalog, executor, search scope, and navigation destination are retired. Compatibility cases remain only to decode old layouts/actions and route them to a supported destination. AI sequential tool calls, task cancellation/progress, native tools, extensions, and Notes remain separate infrastructure and must continue to work.

## Audio output

The shared Core Audio service enumerates live devices with output channels, tracks the default output by stable UID, observes device/default changes, checks writable output volume and mute, and verifies a requested switch by reading the system default again. The picker is exposed in Search, General → Audio, and the Activity Shelf when that shelf is visible. It does not pair Bluetooth devices or claim to route every application independently.

The focused fake-HAL tests verify UID switching, failure to claim success when the setter is ignored, volume/mute support, favorites, observation, and Search routing. Synthetic offscreen light/dark rendering has been checked; hardware switching, Bluetooth disconnect/reconnect, performance, live-window appearance, and VoiceOver still require real macOS QA.

## Mail safety gate

Source now includes account-scoped Mail reading, draft creation, and reviewed send/reply paths with a persistent pending-send journal. Sending defaults off, and an Apple Mail acceptance result is not proof of delivery. A single user-requested self-addressed live test appeared in Inbox, but Mail had no matching Sent item and retained an outgoing item; the result remains unreconciled and the send must not be repeated merely to investigate it. Synthetic-account Apple Events, signed-app Automation, account identity, attachment handling, timeout uncertainty, no-duplicate behavior, and final-build send/reply acceptance still require validation. Do not use a third-party recipient as a test.

The release may not be accepted or published as the requested major release while this gate is open.

## Release notes, history, and tour

The production updater is Sparkle; the signed-custom updater remains an explicit recovery/testing backend. The new release-history layer is informational and cannot authorize installation. GitHub release metadata is sanitized and saved locally under `Application Support/Lima/Updates/release-history.json`. Published notes can include a fenced `lima-release` JSON manifest; only registered internal destinations decode. Version/build matching activates staged notes after a verified signed-custom receipt or a changed running version after Sparkle's signed replacement. Failed or rolled-back installs do not match.

The separate `onboarding-state.json` file records first show, last step, completion, skip, and dismissal by version/build/onboarding ID. A shown tour is not forced open after a crash or dismissal. The tour uses synthetic Mail examples, does not change audio, and does not request Mail Automation. Current Settings spotlight targets are Audio, Mail, and Version History; if a target is not visible, the user may scroll or continue. Manual replay is in Version History when a matching installed major manifest exists.

The publication notes must be saved as `docs/releases/vX.Y.Z.md` for the exact immutable tag; `scripts/release_stage.sh` attaches that file to the GitHub draft. The manifest's `version` must match the tag without `v`, and an optional `build` must match the installed bundle. Do not add arbitrary routes, scripts, or remote URLs to destinations. Example shape:

```lima-release
{
  "version": "X.Y.Z",
  "channel": "stable",
  "importance": "major",
  "title": "A more focused Lima",
  "summary": "Native audio controls and a simpler workspace.",
  "highlights": [
    {"id": "audio-output", "title": "Audio Output Selection", "destination": "settings.audio"}
  ],
  "sections": [
    {"category": "newFeatures", "markdown": "- Select connected audio outputs from Lima."},
    {"category": "removedFeatures", "markdown": "- The dedicated Workflows product has been retired."}
  ],
  "requiresOnboarding": true,
  "onboardingID": "major-release-introduction"
}
```

Other supported section keys are `improvements`, `fixes`, and `securityAndCompatibility`. The active renderer strips external links and HTML from fetched notes, and the only published-release link must be an HTTPS GitHub URL.

## Synthetic visual-audit artifacts

The debug-only offscreen audit renders the production Audio picker, Mail Settings, update presentation, and Mail tutorial spotlight with synthetic devices and release metadata. Run it with `LIMA_TEST_MODE=1 .build/debug/RayPlacement --visual-audit docs/releases/screenshots/major-release --major-release-only` after `swift build`. The eight `*-synthetic-{light,dark}.png` files are under `docs/releases/screenshots/major-release/`. The test path does not read real Mail accounts or audio devices and does not send mail, switch outputs, or install updates. These images document appearance, not live hardware or signed-update acceptance.

## Required pre-publication checks

- Review the synchronized source tree and commit/CI results; do not tag an unreviewed dirty tree.
- Run the complete bounded Swift test suite, release build, release consistency checks, and signed-hosted workflow for the exact version.
- Validate Workflows export/cleanup and unrelated AI, Search, Notes, Extensions, Terminal, and browser behavior.
- Validate audio device enumeration/switch/volume with built-in, Bluetooth, USB/display, disconnect, and macOS-initiated changes.
- Validate Mail sending/replies with a synthetic account, final-message approval, account scope, Apple Automation, and uncertain timeout behavior.
- Review the synthetic light/dark screenshots and capture live-window counterparts when the release candidate is ready; verify VoiceOver, keyboard navigation, Reduce Motion, and small windows.
- Confirm installed release notes, offline history, and onboarding after a successful signed update; confirm neither appears incorrectly after a failed update or rollback.

Synthetic screenshots and source compilation do not imply live Mail-send, real-device audio, signed-install, CI, tag, or deployment success.
