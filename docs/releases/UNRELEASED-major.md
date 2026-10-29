# Unreleased major Lima release — draft, do not publish

This is a working release-note entry. Replace this file with `docs/releases/vX.Y.Z.md` only after a version is chosen and all acceptance gates pass. Do not publish this draft as a completed Mail-sending release.

## New Features

- Select connected macOS audio outputs from Search, General Settings, or the Activity Shelf when it is visible. The picker reports the actual system default and offers volume controls only when supported.
- Review update highlights and release notes in Lima before using the signed installer. Previously installed notes are retained locally in Version History.
- A skippable introductory tour can point to real Settings controls and uses synthetic Mail examples.
- Mail Settings offers account-scoped access and outgoing controls, a nonprompting Automation status snapshot, explicit connection testing, and an Automation Settings link. Reviewed compose and reply paths exist but are not yet release-accepted.

## Improvements

- Search includes audio-output terms such as “speakers” and “airpods” without enumerating devices while typing.
- Saved legacy Workflows definitions are preserved as inactive local snapshots with explicit export and confirmed cleanup controls.
- Background update discovery saves informational notes without opening an intrusive modal automatically.

## Removed Features

- The dedicated Workflows editor, catalog, execution surface, Search scope, and navigation entry have been retired. AI multi-tool execution and extensions remain available.

## Security and Compatibility

- Audio selection is verified against the system default before Lima reports success.
- Update metadata cannot authorize installation or execute arbitrary internal routes. Sparkle and the recovery updater retain their existing signature/digest checks.
- Mail sending is off by default and requires exact-message review. Apple Mail accepting a send request does not prove delivery; one self-addressed test remains unreconciled, so it must not be retried automatically. Synthetic-account and signed-app Mail QA remain release blockers.

## Verification status

Development checks: all 756 discovered Swift tests and a warning-free `swift build -c release` passed. Release-metadata consistency, the deterministic Workbench gate, release dispatcher tests, and hosted-release configuration checks also passed; earlier light/dark synthetic screenshot renders are not final-build live acceptance. Apple Mail send/reply reconciliation, permissioned Messages QA, real-device audio, signed-install/onboarding, live-window accessibility and appearance, exact-commit hosted CI, signing, and publication remain pending.
