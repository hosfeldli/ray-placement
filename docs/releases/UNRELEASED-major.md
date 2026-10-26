# Unreleased major Lima release — draft, do not publish

This is a working release-note entry. Replace this file with `docs/releases/vX.Y.Z.md` only after a version is chosen and all acceptance gates pass. Do not publish this draft as a completed Mail-sending release.

## New Features

- Select connected macOS audio outputs from Search, General Settings, or the Activity Shelf when it is visible. The picker reports the actual system default and offers volume controls only when supported.
- Review update highlights and release notes in Lima before using the signed installer. Previously installed notes are retained locally in Version History.
- A skippable introductory tour can point to real Settings controls and uses synthetic Mail examples.
- Mail Settings shows a nonprompting macOS Automation status snapshot for a running Mail app and offers explicit connection testing and an Automation Settings link.

## Improvements

- Search includes audio-output terms such as “speakers” and “airpods” without enumerating devices while typing.
- Saved legacy Workflows definitions are preserved as inactive local snapshots with explicit export and confirmed cleanup controls.
- Background update discovery saves informational notes without opening an intrusive modal automatically.

## Removed Features

- The dedicated Workflows editor, catalog, execution surface, Search scope, and navigation entry have been retired. AI multi-tool execution and extensions remain available.

## Security and Compatibility

- Audio selection is verified against the system default before Lima reports success.
- Update metadata cannot authorize installation or execute arbitrary internal routes. Sparkle and the recovery updater retain their existing signature/digest checks.
- Live Apple Mail sending remains **disabled** pending synthetic-account and signed-app QA; this release must not be accepted as complete until it is safely enabled and validated.

## Verification status

Development checks: all 744 discovered Swift tests passed; `swift build -c release`, release-metadata consistency, and eight light/dark synthetic screenshot renders passed. These are not live acceptance checks. Apple Mail send/reply, real-device audio, signed-install/onboarding, live-window accessibility and appearance, hosted CI, signing, and publication remain pending.
