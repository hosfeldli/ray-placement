# Next Lima publish: embedded Browser and AI Workbench gate

The original target for the next publish was the site-agnostic, shared human/AI Lima Browser **and** the task-centered AI Workbench specified in the October 15 proposal. Keep `v3.14.24` immutable; use a new version and tag. The checklist below remains open and must not be represented as complete.

## Explicit limited-release exception for v3.14.25

On October 16, 2026, the requester directed publication even if all post-v3.14.24 asks cannot be fully verified. They chose to proceed and disclose that the earlier Search/Workspace proposal attachment was unavailable. This is an exception to the complete-scope gate, **not** a declaration that any unchecked item passed. Publish only the implemented subset, with the known gaps and performance uncertainty in `docs/releases/v3.14.25.md`. Preserve automated source checks, exact-commit CI, immutable tagging, signed artifact verification, and public-asset verification; do not bypass a failed integrity or distribution check.

## Explicit limited-release exception for v3.14.26

On October 16, 2026, after the assistant reported that the Browser/Terminal UI pass was not release-ready and that real-window interaction and broader Workbench scope remained unverified or incomplete, the requester explicitly instructed publication. This authorizes only the implemented incremental changes in `docs/releases/v3.14.26.md`; it does not close any unchecked gate. Preserve exact-commit CI, immutable tagging, signed artifact checks, and public-asset verification. Disclose the live-window, real-site, and performance limitations rather than treating offscreen fixtures or unit tests as full acceptance.

## Explicit limited-release exception for v3.14.27

On October 17, 2026, the requester directed completion of blocking development and publication while allowing remaining verification-only steps to be non-blocking. This authorizes only the implemented stabilization and AI response-presentation fixes in `docs/releases/v3.14.27.md`; it does not close the packaged-app repaint, real-site Browser, performance, or full Workbench-scope gates. Preserve exact-commit CI, immutable tagging, signed artifact checks, and public-asset verification. Do not represent unperformed checks as passed.

## Explicit limited-release exception for v3.14.28

On October 18, 2026, after the assistant reported that real Claude CLI inference and live-window Browser pointer/AI sidecar acceptance remained unverified and the complete-scope Browser/Workbench gate was still open, the requester explicitly instructed publication. This authorizes only the implemented Grammar CLI and agent-workspace changes described in `docs/releases/v3.14.28.md`; it does not close any unchecked gate. Preserve exact-commit CI, immutable tagging, signing, artifact integrity, and public-asset verification. Disclose the unverified live-window, real-site, Claude, and performance limitations rather than treating unit tests or offscreen renders as full acceptance.

## Explicit limited-release exception for v3.14.29

On October 23, 2026, after the requester was told that the Browser/AI Workbench, live-device, and packaged-app acceptance gates remained open despite successful CI on the development commit, they explicitly authorized a **documented limited v3.14.29 release with those gaps disclosed**. This permits publication of only the implemented subset described in `docs/releases/v3.14.29.md`; it does not close or mark any unchecked item below as passed. Preserve successful CI on the version commit, immutable tagging, hosted signing, artifact-integrity checks, and verification of public assets. Do not bypass a failed build, security, signing, or distribution check.

## Explicit limited-scope exception for v4.0.0

On October 29, 2026, after the requester was told that Mail reconciliation and Browser/Workbench acceptance remained open, they directed publication of `v4.0.0` and supplied launch notes that explicitly disclose the unresolved Mail live-send case, Messages attachment/monitoring gaps, and broader real-site and installed-update acceptance. This authorizes only a **limited-scope major release** of the implemented subset described in `docs/releases/v4.0.0.md`; it does not mark any unchecked item below complete or justify claiming full Browser, Workbench, or Mail-send acceptance. Preserve exact-version CI, immutable tagging, hosted signing, artifact integrity, and public-asset verification. Do not bypass a failed build, security, signing, or distribution check.

## Stabilization self-test gate for future releases

Release build, staging, and final publication run the deterministic `scripts/release_workbench_gate.sh`. It requires isolated WebKit semantic read/find/type/click/user-takeover checks, a sandboxed PTY round trip, registry and local-file fixtures, a fake Swift app-server structured-tool/streaming continuation test, and AI response-presentation regressions. `scripts/release_workbench_gate.sh --live` additionally checks a signed-in Codex app-server call to `lima_capabilities` with same-turn continuation on a developer Mac; the hosted runner does not depend on a personal signed-in CLI session. Settings → AI Chat → AI Workbench Diagnostics provides native/provider checks on demand. This automated gate does not close the broader real-page, accessibility, performance, or Workbench-scope checklist below.

## Separate live-site booking gate

The opt-in real-site reservation gate is specified in [LIVE_SITE_BOOKING_GATE.md](LIVE_SITE_BOOKING_GATE.md). Its local validator and negative tests do not make a booking or close the gate. It remains **OPEN** until a user-authorized real-site run in the packaged embedded Browser produces fresh read, exact-call approval, final-action, and actual matching confirmation evidence, followed by interactive manual attestation. Deterministic fixtures and the Workbench `--live` CLI test are not substitutes. This gate does not add a scheduler.

## Separate AI response-presentation gate for future releases

The “Working…”-after-completion and stale reasoning-summary defects are separate from Browser/tool readiness. The automated Workbench release gate now includes final-answer terminalization and successive live-reasoning presentation regressions, plus a fake Codex app-server check for streamed and completed reasoning summaries. Production Codex chat uses the streamed app-server bridge, not the legacy buffered `codex exec` adapter; the latter remains only for legacy tests and is not a justification for claiming Codex chat still waits for process exit.

- [ ] Verify in the packaged app that the answer and reasoning disclosure update without toggling, and that a completed run with a ready composer never displays an active placeholder.
- [ ] Repeat with provider completion, cancellation, approval continuation, and a reasoning-heavy Codex turn. The automated tests cover state and protocol boundaries but do not replace a real-window repaint check.
- [ ] Keep this presentation gate open until those checks pass on the final release candidate.

## Browser replacement

- [ ] One shared Workspace Browser with Off, Read Only, Navigate, and Full Control; one live Browser AI-control authority across schema exposure, execution, settings, and approval continuation.
- [ ] Generic semantic snapshots with readiness, verified links, controls, headings, rows, route/document/mutation identity, open-shadow traversal, and eligible frames. Targets must carry frame identity and become stale on route, DOM, scroll, or user changes.
- [ ] Bounded read/find/wait/scroll/scan, ordinary form interactions, new-window handling, tab management, screenshots, native AI feedback, and post-action verification. Protect sensitive and destructive controls even in Full Control.
- [ ] Background tab suspension/pooling and complete disk-backed Browser-result retrieval, without publishing giant payloads through SwiftUI conversation state.
- [ ] Remove the Browser Bridge extension, native host, service, XPI and signing/package paths, setup UI, site grants, Salesforce-specific browser adapter, retired tool IDs, and obsolete tests. Rework release packaging and CI to assert their absence.
- [ ] Add live/local WebKit regressions for SPAs, virtualized lists, open shadow roots, same- and cross-origin frames, safety, user takeover, navigation, form verification, screenshots, and bounded memory/output.

## AI Workbench scope

- [ ] Make the AI workspace a persistent work environment independent of conversations, with an explicit Read Only / Ask for Actions / Full Control choice, independently configured Browser control, visible access state, and durable security-scoped bookmarks for user-attached folders. Enforce physical-root/path boundaries and revocation across every tool family.
- [ ] Replace Process-per-command AI sessions with a persistent, user-visible PTY Terminal shared by the user and AI. Implement stdin, bounded output cursors, wait/status, resize, interrupt/close, resource budgets, and first-class AI-owned long-running process/port tracking; support dependency installation and network access only within the explicitly selected authority.
- [ ] Connect Terminal development servers to the same visible Browser for localhost DOM/screenshot inspection and corrective iterations. Preserve or explicitly constrain pooled Browser state/history; verify popup, frame, clipping, sensitive-action, and accessibility behavior on real pages.
- [ ] Introduce a unified off-main tool runtime/registry with consistent access enforcement, bounded artifacts, activity events, machine-actionable failure codes, recovery hints, observable postconditions, and final run verification. A dispatched action is not proof of its requested effect.
- [ ] Provide workspace-relative, revision-aware files/patches and structured Git, code search, web research, HTTP/download, document, data, computation, text, archive, and artifact/deliverable tools. Keep large results out of SwiftUI conversation state.
- [ ] Add run-scoped plans and controlled helper agents sharing workspace, Browser, Git, and artifacts while using separate Terminal sessions; enforce resource budgets and initially disable recursive spawning.
- [ ] Prevent substantial runs from completing without evidence for major claims or while blocking Terminal, Browser, file-write, or verification operations remain unresolved. Mark intentional detached servers explicitly.
- [ ] Pass end-to-end research/build/run/inspect/repair/verify/deliverable scenarios in an attached existing project, including recoverable tool misuse and a failed postcondition, without manual information transfer.

## Existing architecture gates

- [ ] Make the off-main AI execution engine the sole owner of run lifecycle, approval continuation, cancellation, errors, and task registry state.
- [ ] Finalize durable message storage without eager full-conversation publication on the main actor; prove large payloads are not repeatedly copied into UI state.
- [ ] Profile real Search, AI streaming, Workspace switching, Notes edits, and window resizing against `v3.14.24`, including frame pacing and memory, then fix regressions.

## Release validation

- [ ] Run the full Swift test suite, Debug and Release builds, packaging/CI checks, visual audit, focused manual Browser safety/accessibility review, and Workbench end-to-end acceptance scenarios on the final source tree.
- [ ] Review `git diff --check`, repository status, version metadata, migration behavior, release assets, and signed app/DMG contents. Confirm no Bridge/XPI/native-host artifact remains.
- [ ] For full-scope release readiness: complete all gates, commit and push, wait for CI on that exact commit, prepare a new version, create an immutable tag, stage and verify the hosted release, then publish and verify the public artifacts.

Passing unit tests or a build alone is not release approval. This checklist records scope, not a claim that any item is complete.

## Development evidence, October 15, 2026 (not release clearance)

- After the expanded Workbench proposal, the Browser destination policy now permits HTTP only on exact loopback hosts (`localhost`, `127.0.0.1`, `[::1]`) with valid ports and no embedded credentials; the address field recognizes schemeless loopback previews while other schemeless addresses stay HTTPS. The app plist adds the local-network ATS exception. A focused URL-policy test passed (`/tmp/lima-localhost-test-86.log`), and a loopback-only HTTP server/WebKit semantic-read test passed (`/tmp/lima-localhost-webkit-88.log`). Non-loopback HTTP remains rejected. This does not establish real packaged-app/manual behavior.
- Browser and current bounded AI Terminal tools now return stable machine-readable failure codes and recovery hints for recognized errors; `terminal_wait` and status payloads identify nonzero exits, launch failures, timeouts, and cancellation. Two focused feedback tests passed (`/tmp/lima-workbench-feedback-tests-87.log`). This is feedback plumbing, **not** the unified tool runtime, persistent PTY, attached-folder authority, or final verification engine.

- The current development tree passed 479 Swift tests (`/tmp/lima-full-tests-91.log`, exit 0), including the new loopback WebKit and structured-feedback regressions, Browser page-result revocation, transformed frame geometry, provider screenshot encoding, and tab pooling. An earlier full run timed out only in WebKit fixture startup under parallel load (`/tmp/lima-full-tests-79.log`); its isolated rerun passed, and the readiness allowance was widened without changing the takeover assertions. The later full runs passed.
- The current development tree passed a Release build (`/tmp/lima-release-build-92.log`, exit 0). An earlier tree passed an offscreen visual audit (199 PNGs, zero failed renders in `/tmp/lima-visual-audit-85.log`, exit 0). Release dispatcher and cloud-configuration checks passed earlier; the current tree passed plist validation, the local-network ATS setting check, and staged/unstaged whitespace checks. The visual audit is not a live-page manual Browser review and must be rerun on the final source tree.
- Embedded Browser now has bounded frame-aware semantic reads/actions, open-shadow text, readiness and wait conditions, guarded navigation and tab management, native target feedback, and a six-live-view cap over up to 20 logical tabs. Its private JPEG captures have pre/post semantic safety checks and can be supplied ephemerally as image input to API providers after tab/read-authority validation. CLI continuations remain text-only. Focused screenshot/provider tests passed (`/tmp/lima-screenshot-multimodal-82.log`). Real provider/model compatibility and manual cross-origin, nested-frame, clipping, and accessibility behavior have not been verified.
- Oversized Browser results use private tab-scoped blobs and bounded UTF-8 chunks, revoked on tab close, user takeover, and Browser-data clearing. Navigation acknowledgements remain returnable after page revocation. AI chat and Home publish compact summaries, but persisted history still eagerly hydrates full bodies on the MainActor.
- Retired Bridge extension, host, Salesforce adapter, XPI assets, setup/signing paths, and dedicated tests were removed from the source tree. Launch migration removes retired preferences and only matching Lima-owned native-host manifests. Earlier static checks found retired tool IDs only in migration data, not active Browser tools; final-tree packaging and signed-artifact inspection are still required.
- Still open: preserve or explicitly constrain state/history when pooled tabs suspend; complete popup, sensitive-action, real cross-origin-site, and manual Browser review; make the off-main engine sole AI run authority; finalize lazy/durable message presentation; and profile real Search, AI streaming, Workspace switching, Notes edits, and resizing against `v3.14.24` for frame pacing and memory. Hosted CI on a release commit, full packaging checks, and signed app/DMG inspection have not occurred. **The complete-scope release gate remained closed at this point.**

## Development evidence, October 16, 2026 (not release clearance)

- The opt-in AI Workspace shell is now a user-visible SwiftTerm PTY shared by user input and `terminal_write`. It retains shell state, supports bounded read/wait cursors, interrupt, HUP-with-bounded-escalation termination, and `terminal_resize` with kernel PTY size readback. The no-network sandbox was amended for terminal ioctls so interactive job control and `stty size` work. The eight focused Terminal regressions passed (`/tmp/lima-pty-suite-106.log`, exit 0), including session ownership, write confinement, and the shared PTY. This remains conversation-owned and confined to the fixed Desktop workspace; attached-folder authority, networked dependency installation, and first-class process/port tracking are still missing.
- The development tree passed 480 Swift tests (`/tmp/lima-full-tests-111.log`, exit 0) and a Release build (`/tmp/lima-release-build-110.log`, exit 0). A five-second WebKit background-tab fixture timed out once under the full parallel suite (`/tmp/lima-full-tests-107.log`); its 15-second readiness allowance preserves the same semantic and deferred-tab assertions, and the focused and later full runs passed. These results predate any further Workbench changes.
- The correctly invoked offscreen visual audit completed with 199 PNGs and zero failed renders (`/tmp/lima-visual-audit-113.log`, exit 0). Static release-dispatcher, cloud-configuration, plist, and staged/unstaged whitespace checks passed. The first audit invocation omitted its required output directory and launched the ordinary app instead; it was stopped without a render result. Generated fixtures are not a live Browser safety/accessibility review, real-UI performance profile, or task-centered Workbench acceptance run.
- All checklist items remain open pending full integration and final-tree validation. In particular, persistent attached work environments, unified off-main run/tool authority, broad native tool families, verified final task completion, and release packaging/CI/signed-artifact checks are not complete. **The complete-scope release gate remains closed; see the explicit limited-release exception below.**

## Development evidence, October 22, 2026 (not release clearance)

- The current dirty tree already uses `BrowserWebViewHost` in both `makeNSView` and `updateNSView`, with tab-local `BrowserTabContent` identity. The focused A→B→C→A test verified the mounted `WKWebView` and each page marker; a new remount/late-teardown test passed. Foreground/background and suspended-tab fixtures also passed. These are not packaged-app or real-window acceptance.
- Bounded Terminal commands now deliver output through an ordered `AsyncStream` drain instead of `DispatchQueue.main.sync`. A new 6,000-line output-order/completion fixture and the existing streaming/cancellation fixture passed; the owned-process safety fixture also passed. This does **not** add artifact-backed logs, project-owned process groups, an actor process manager, or the proposed Process panel.
- A Release build and `git diff --check` passed on this working tree. The activity timeline, visible Browser overlay redesign, 100+-tool-call end-to-end run, live-site gate, and complete Workbench performance/release gates remain open. No commit, package, signing, or publication was performed.

## Visual Browser development evidence, October 23, 2026 (not release clearance)

- On `feature/visual-browser-foundations`, the existing exact-call visual-click review now includes bounded visible deposit, fee, total, and cancellation terms only when the safe page summary has the screenshot hit's exact page identity. A changed identity withholds the review; the semantic and visual review tests passed.
- An internal native pointer-move path now requires a task/tab/capture lease, fresh page and protected-region preflight, Accessibility access, Lima's foreground Browser window, unobscured AppKit hit geometry, and a checked AppKit-to-Quartz projection. It posts a non-committing move only to Lima's process and invalidates the capture afterward. Retina crops, flipped views, negative-origin displays, invalid geometry, and detached-WebView rejection passed focused tests. No model-facing native click, typing, drag, or Visual Only mode is enabled, and native event delivery in a packaged app has **not** been verified.
- The committed batched `make test` runner passed all **634/634** discovered Swift tests (`/tmp/lima-visual-next-pass-tests.log`), and `swift build -c release` passed (`/tmp/lima-visual-next-pass-release-build.log`). This is source-level evidence only. Auto-approve Nonpayment, task-scoped authority, a cross-input financial gate, full visual action verification/recovery, independent mode controls, real-site booking, live-device permissions, packaged-app acceptance, and the broader Workbench gate remain open.
