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

## Signed 1.0.0 installation and initial live checks

Following preparation commit `2e03f79`, the AMO attempt ended without a returned
XPI. The user confirmed approval and downloaded the artifact; no duplicate
submission was made. The downloaded XPI matched the submitted source and
contained signature metadata. SHA-256:
`8767caf28b43eacc07edca6c633b53cbe98fe49f0bbb6ee63a446ad6abc42c22`.

- The user reported signed 1.0.0 installed and enabled in Zen with normal
  signature enforcement, an end-to-end connection, successful granted
  example.com reading, and rejection of a new read after revocation.
- Both native-host manifests were independently checked against the packaged
  helper path and fixed companion allowlist.
- Packaging with the unchanged XPI passed, including app/helper verification;
  evidence: `.build/amo-signed-package.log`.
- Release versioning, dispatcher, installer, update-verifier and
  certificate-backed replacement regressions passed. The certificate-backed
  follow-up is recorded in `.build/amo-certificate-update-tests.log`.
- The user requested persistent interaction access before reporting the remaining
  action-consent/Stop/Escape checks. Those checks are **not** recorded as passed.

## Persistent access follow-up (companion 1.1.0)

At the user's request, the companion now separates persistent reading from
explicitly confirmed persistent interaction access for each exact HTTPS site.
Read grants are not automatically promoted. The interaction choice covers only
the four existing typed tab actions. Cross-site navigation requires both sites.
Ask every time, revocation, restart, storage failure, stale URLs, private tabs,
connection generations and cancellation retain fail-closed behavior. AI still
exposes only the existing opt-in read tools.

- **34 companion/popup tests**, **11 offline signing tests**, real debug-helper
  smoke and Mozilla lint (zero errors/notices/warnings) passed.
- **237 Swift tests passed**, including compiling the updated Settings surface.
- Evidence: `.build/bridge-access-tests.log`,
  `.build/bridge-access-swift-tests.log`; whitespace checks passed.
- Unsigned 1.1.0 package SHA-256:
  `20a97b2597221f8a56213c20816d394a6ec0064706ea20a47b17b8d979611bbf`.
- These are automated checks, not live persistent-mode acceptance. The installed
  signed 1.0.0 and running app have not been overwritten. New 1.1.0 signing,
  installation, rebuilt-app acceptance, remaining browser/provider/device gates
  and public deployment are pending at this checkpoint.

## Local signed companion delivery update (1.1.0)

The user placed the approved Mozilla-signed 1.1.0 XPI in Downloads. Its SHA-256 is
`1bd3d27439192afe5c47f27ca64a381fd17d1f679d3bc578b2da56efd5726d86`; its bytes
match the packaged companion and the existing source/signature receipt. The app
was rebuilt as `build/Lima.app` (3.14.2) without repacking or modifying the XPI.

- Deep/strict `codesign --verify`, app verification, companion source/signature
  metadata verification, digest equality, `git diff --check`, Python syntax, and
  release-script shell syntax passed.
- The app contains **Save Companion XPI…** (save panel defaults to Downloads) and
  **Setup Guide…** in Settings → Browser Bridge. The comprehensive guide is also
  available at `docs/BROWSER_BRIDGE.md` and in the app's packaged companion files.
- Moved to the previously unused `~/Applications/Lima.app`, launched from that
  deployed path, and verified the moved app and bundled XPI afterward. The visual
  pass opened Browser Bridge Settings, confirmed **Save Companion XPI…** is enabled
  and its save dialog defaults to Downloads with the `.xpi` filename, then opened
  the complete numbered Setup Guide. The dialog was cancelled without exporting a
  duplicate file. Live browser acceptance still requires user-side installation.
- Local build remains signed by the pinned **local** code-signing identity; it is
  not Developer ID notarization and is not a published deployment.
- The repository build copy was moved to `~/Applications/Lima.app`, freeing its
  roughly 560 MiB bundle; release preflight must be rerun before any release build.
  At the preceding check, preflight was blocked by the dirty worktree, 32 commits
  ahead of upstream, and about 398 MiB free versus the 5 GiB minimum. Existing
  `dist` artifacts were not deleted. Published v3.14.2 was not overwritten.
- The user confirmed that the Zen integration works and instructed us to assume
  it works for this deployment request. Record this as user-reported acceptance,
  not an independently reproduced test in this session. The broader provider/device
  matrix and complete browser release matrix remain unverified; full release sign-off
  remains pending.

## Deployment request checkpoint

The user explicitly requested deployment and said to assume the Zen integration
works. The deployed local app remains `~/Applications/Lima.app` (3.14.2) with the
verified Mozilla-signed companion 1.1.0 XPI. The browser integration status is
user-reported, not independently re-tested in this session.

A new distributable release could not be started: `scripts/release_preflight.sh
--tag v3.14.3` stopped at the dirty-worktree gate. At the latest check the branch
was 32 commits ahead of `origin/reliability/grammar-and-notes-routing`, with 14
modified/untracked paths, and the volume had only 569 MiB free against the 5 GiB
release-build minimum. The existing public `v3.14.2` release was left untouched;
no commit, push, tag, draft, upload, or publication was made. Full release sign-off
remains pending.

## Delivery boundary

The locally deployed app is `~/Applications/Lima.app`; its signature, version,
bundle ID, and bundled signed-XPI digest were verified previously. No new release
version/tag, GitHub publication, replacement in `/Applications`, or production
notarization has occurred. Full release sign-off remains pending.
