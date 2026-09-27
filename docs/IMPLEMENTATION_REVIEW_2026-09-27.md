# Implementation review — September 27, 2026

## Checkpoint and scope

Branch: `reliability/grammar-and-notes-routing`  
Reviewed application code checkpoint: `d281bd9`

This is an implementation and automated-verification checkpoint, **not a sign-off
on the entire manual release matrix**. The bridge remains opt-in; AI tool execution
continues through the existing shared runtime and read-only policy. No new
workspace, provider runtime, task registry, or extension package format was added.

## Changes completed during the closing pass

- `3a92fa2`: compatible-provider tool continuations, grouped multimodal/parallel
  tool history, and fail-closed handling of incomplete or failed streams.
- `a4fb476`: Gemini EOF frames now retain text, tool calls, and usage; completion
  requires a successful terminal reason; malformed/blocked/truncated streams fail
  without publishing successful completion. Tool results encode as objects.
- `3cb061c`: compact AI menus, accurate provider/local-history language,
  guarded sidebar deletion and draft cleanup, updated Dictation settings wording,
  selected-provider runtime diagnostics, and a real AI Settings preview.
- `d281bd9`: shared AI tool toggles (including opt-in browser tools) in Command
  Center, correct Dictation/Context Shelf shortcut assignment IDs and conflict
  indicators, and shortcut reverse lookup in Command Center.

Earlier review checkpoints retained:
- `d31a0ba`: native table field editor, visible selection, TSV/HTML paste,
  cell navigation, and Bridge Escape navigation.
- `d1d35bc`: bounded shared SSE framing and categorical provider/transport
  diagnostic sanitization.
- `7882845`: shared provider Settings and configuration/credential safeguards.
- `745f781`: opt-in Zen/Firefox companion, native helper, installation, Settings,
  AI read tools, lifecycle, packaging, and regression coverage.

## Verification performed

| Check | Evidence / result |
| --- | --- |
| Full Swift suite | **237 tests passed**, `.build/final-command-center.log` |
| Browser companion suite | **16 tests passed**, `.build/final-bridge-verification.log` |
| Actual debug native helper | Split frames, duplex relay, cancellation, direction and identity smoke test passed |
| Unsigned XPI | Source verification passed; two builds produced identical SHA-256 |
| Release app | `make package` rebuilt and verified `build/Lima.app` using the configured stable **local** signing identity |
| Whitespace validation | `git diff --check` passed at the source checkpoint |
| Visual fixtures | Updated AI conversation and Notes table inspected; prior Dictation and real AI Settings fixture inspections retained |

Unsigned XPI SHA-256:
`fb1b52af4ea42ac789f466fa8c3e843c3b925ce1a2e0043bba97bfcb785bbd0f`

Package log: `.build/final-package-review.log`.
The build still reports the pre-existing unused-variable and deprecated substring
warnings in `InlineMarkdownEditor.swift`; they are not test or build failures.

The Swift count includes guarded opt-in live-AI tests. A passing default run does
**not** mean those tests contacted a real provider. No real provider call, live
microphone transcription, or signed browser installation is certified here.

## Requirement coverage and evidence boundaries

| Area | Inspected implementation / regression evidence | Remaining acceptance |
| --- | --- | --- |
| Escape / explicit Stop / Return | Actual launcher Escape route, task retention, cancellation, empty/active composer tests | Live hotkey/hidden-window interaction |
| One Workspace | Module entry-point window reuse, coordinator and restoration tests | Repeated hotkeys, rapid switching, Spaces/fullscreen/monitors |
| Notes tables | Native field editor typing/selection, tabular paste, Tab/Return, sizing and light/dark contrast tests; real inline-editor fixture | Physical mouse selection, paste and long-table editing in production Workspace |
| Providers | Shared configuration, Keychain migration, model restoration, endpoint policy, instruction continuations, malformed/failed stream tests | Real OpenAI/Claude/Gemini/compatible text and tool conversations, cancellation and network loss |
| Dictation | On-device Apple live capture path; short Whisper segment planning, stable committed-delta assembly and target tests | Live partial latency, external insertion, microphone changes, hidden Workspace and sleep/wake |
| Manifest v3 / tools / skills / agents | Manifest/schema/capability checks, approved typed adapters, explicit AI opt-in, shared conversation configuration | Real installed extension contribution behavior |
| Command Center / Settings | Catalog filters, provider controls, shared tool toggles, canonical shortcut routing and reverse lookup tests | Interactive inspector and shortcut-reassignment UI pass |
| Extension installation/update | First-install failure visibility, atomic success and rollback, approval metadata and capability validation tests | Live Store install, update/reinstall/uninstall against release services |
| Recovery / diagnostics | Safe identifier restoration, no task replay, bounded private runtime diagnostics, sanitized failures | Real crash, relaunch and interrupted-work presentation |
| Quiet paste / emoji / terminal / formatter | Silent-success policy, emoji aliases/ranking, workspace state and formatter/core tests | Emoji popover focus, terminal wrapping/single-shell UI and formatter sizing |
| Browser bridge | Native installation safety, framing, service correlation, cancellation, consent/grant/revocation/navigation races, bounded page reads | Signed target-browser installation and complete manual bridge matrix |

This table records evidence, not a claim that every requested end-to-end behavior
has been manually exercised.

## Outstanding release gates

### Browser distribution

The bundled companion is **unsigned**. Stable local Apple signing of Lima and its
native helper does not provide Mozilla signing for the XPI.

1. Obtain the Mozilla-signed artifact for
   `lima-browser-bridge@liamhosfeld.com`.
2. Package it using the documented `LIMA_BROWSER_BRIDGE_SIGNED_XPI` input.
3. Install in the target Zen and Firefox builds and confirm native-host discovery.
4. Run every item in `docs/BROWSER_BRIDGE.md` under **Manual release gate**:
   grants/private-window denial, revoke-in-flight, every tab consent action,
   background focus, exact Salesforce lookup, reconnect/restart, move/repair,
   helper removal/reinstall, pending-approval Stop/Escape, and multiple sessions.

The package verifier checks source equality and signature metadata; only target
browser installation verifies Mozilla trust. No signature-check bypass is used.

### App manual matrix

- Multiple monitors, fullscreen applications, Spaces, Notes and Activity Shelf
  over fullscreen.
- Rapid Notes/AI switching and repeated hotkey toggling.
- AI, Dictation and extension work while their surfaces are hidden.
- Light/dark appearance changes; Notes table mouse/keyboard/clipboard interaction.
- Sleep/wake, microphone-device changes and AI network interruption.
- Real-provider tool continuations, error states and explicit cancellation.

UI previews use fixture data. Screenshots/accessibility inspection are not
substitutes for these interaction checks. The inspected AI menu expansion defect
is visibly corrected; the Notes table fixture is readable and aligned.

## AMO preparation follow-up

Starting checkpoint: `f439b29`. The chosen route is an **unlisted** Mozilla-signed
companion bundled through Lima's existing GitHub app release workflow.

- Added `scripts/browser_bridge_signing.py`: pinned web-ext, exact seven-file
  staging, Keychain-only credentials, fixed AMO destination/channel, explicit
  submission, private diagnostics and per-version no-blind-retry receipts.
- Added `scripts/setup_browser_bridge_signing.swift`: local hidden prompts and
  direct Security-framework Keychain writes; its no-side-effect compile check
  passed.
- Declared browsing activity and website content transmission; required built-in
  browser data consent and clarified the popup disclosure. Per-site grants and
  private-window exclusion are unchanged.
- **11 offline signing tests passed**, **16 companion tests passed**, and the
  real debug native-helper smoke test passed. Simulated signing in unit tests
  uses deliberately fake signature metadata, not Mozilla-signed artifacts.
- Mozilla `web-ext 10.7.0` lint completed with **0 errors, notices or warnings**.
  Python syntax and `git diff --check` passed. Tool installation under Node
  23.10.0 emitted transitive engine warnings; use the documented supported Node
  22/24 runtime for reproducible tooling.
- Updated unsigned XPI source verification passed; its SHA-256 is
  `c6c756ac6333187930051e477e421075f2e770c290b78b368a35f4b4741aa868`.
  The earlier hash above belongs to the preceding reviewed companion source.
- Zen **is installed**: 1.22.3b, bundled Gecko 156.0.1. This meets the manifest
  minimum but is not evidence of companion installation. Standalone Firefox was
  not found at `/Applications/Firefox.app`.
- GitHub authentication was available; the branch was 30 commits ahead of its
  upstream before this preparation checkpoint. No push, release version change,
  immutable tag, draft upload or public publication was performed.
- AMO credential provisioning/authentication, actual submission/download, signed
  XPI browser trust, packaged-app acceptance and live browser/provider/device
  checks are **pending**. The existing app package predates these companion
  changes and must be rebuilt with the actual signed XPI.
- See `docs/BROWSER_BRIDGE.md` for setup and interrupted-submission recovery.
  The full application suite's prior **237-test** checkpoint above is retained;
  this follow-up did not rerun or claim new live-provider tests.

## Delivery boundary

`build/Lima.app` is a locally signed, verified build of the source checkpoint.
No release upload, installed-app replacement, production notarization, AMO
submission, native-host registration, or permanent companion installation is
implied by this review.
