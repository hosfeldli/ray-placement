# Lima commercial v1 release roadmap

Status: October 14, 2026 historical roadmap, updated for the Workflows retirement decision. The current major-release gate is `docs/MAJOR_RELEASE_MIGRATION.md`; the embedded Browser gate remains separate. Neither document claims the app is ready to publish or sell.

## Product contract

- **Search** is transient, compact, keyboard-first, and disappears after action.
- **Workspace** persists Notes, AI, Context, Clipboard, and optional history; the dedicated Workflows product is retired.
- **HUDs** briefly report capture, dictation, replacement, task, and AI outcomes.
- Default navigation stays compact around Search, AI, Notes, Dictation, Terminal, Extensions, and Settings. Other utilities remain available through Search/commands without crowding the rail.
- Home resumes work (Continue, Recent, Pinned) instead of cataloging features.
- AI shows recorded completed actions and the current action. It never schedules hypothetical tool calls visually. A model-authored plan, when present, must be labeled tentative and allowed to change.
- The embedded Lima Browser shares human/AI tabs and uses one visible AI Control mode (Off, Read Only, Navigate, or Full Control). Sensitive controls remain protected; local files and terminal actions retain separate policy boundaries.

## Release stages and exit criteria

### 1. Surface and primary-workflow finish

**Implemented / automated evidence:** simplified rail and resume-oriented Home; compact Search changes; shared full/side AI message rendering; deterministic visual audit.

**Exit criteria still requiring hands-on evidence:**
- Verify Search invocation, keyboard results, action dispatch, and dismissal on a clean install.
- Audit major Workspace modules and HUDs in light/dark, compact/full widths, reduced motion, and accessibility sizes. Remove inconsistent row, border, typography, and inspector patterns.
- Exercise selected text → Capture → Save to Note / Add Context / Ask Lima without leaving the source app.
- Exercise Notes editing, checklists, Markdown, undo/redo, dictation insertion, autosave, restart persistence, and instant note search.
- Exercise Context add/search/remove and sequential AI tool calls with cancellation and visible outcomes. Verify archived Workflows definitions cannot execute and remain exportable.

### 2. AI reliability and truthful activity

**Implemented / automated evidence:** response and code-block copy use one exact-text pasteboard path with feedback; live activity is projected from recorded events, expands while working, and collapses after completion. Denied requests do not count as executed actions; stopped work does not read as Done. The latest Swift run passed 333 tests, and the visual audit reported zero failed renders.

**Exit criteria still requiring hands-on evidence:**
- Click response and code-block Copy in both full and compact AI windows; paste into another app and compare exact whitespace/newlines.
- Test live provider send, stream, Stop, retry, timeout, malformed response, approval pause/denial, and partial-answer preservation. The app must remain responsive; cancellation must be prompt.
- Confirm every user-facing error is actionable, with technical detail behind disclosure, and that provider/tool configuration recedes after setup.
- Confirm no pending or imagined tool step is displayed as a completed or scheduled action.

### 3. Embedded Browser acceptance

The old extension/native-host approach is retired. The current implementation uses WebKit inside the Lima Workspace, with the same tabs visible to the person and to AI. It reads generic semantic links, controls, headings, rows, shadow roots, and eligible frames; it does not use a site-specific adapter.

**Exit criteria still open:** complete screenshots, bounded keyboard actions, exact frame overlay geometry, tab suspension/pooling, sensitive-action review, and post-action verification. Exercise SPAs, virtualized regions, same- and cross-origin frames, popups, user takeover, and all four AI Control modes in live Browser sessions. Use `docs/EMBEDDED_BROWSER_RELEASE_GATE.md` as the authoritative next-publish checklist.

### 4. First-run trust and support

**Open release work:**
- A short onboarding path for shortcut selection, explained Accessibility/microphone/speech/file permissions, a Search trial, and optional AI connection.
- A single Permissions screen with current status, rationale, and deep links where macOS supports them.
- A truthful local-by-default privacy statement and an audit that only composer-shown context reaches the configured AI provider.
- Sanitized crash/performance diagnostics with no notes, clipboard, page text, or API keys by default; an in-app problem/feedback route.
- Clear update, uninstall, helper-removal, and data-deletion guidance.

### 5. Release hardening

**Open release work:**
- Measure Search appearance and local-results latency, Workspace/module/note switching, clipboard search, AI first feedback and Stop; log regressions and eliminate main-thread blocking.
- Run the release-candidate matrix: fresh install, old→new updates, signed/unsigned and network failures, interrupted download/install, relaunch/rollback, and clean uninstall.
- Run a small end-to-end regression suite for Search, Notes, Dictation, AI, Clipboard, Context, Extensions, and Browser, plus Workflows-retirement migration tests and visual snapshots.
- Build model-free and full app variants without any legacy Browser extension or native host; verify the app/DMG signatures and the absence of retired assets. Never overwrite a published release.
- Stage a **new** version/tag as a draft only after source is committed, CI is green, browser acceptance passes, and the build matrix is complete. Public publication is a separate review.

### 6. Commercial beta

- Decide one-time license versus free/Pro, account-free default, entitlement boundaries, and support/update term before final onboarding copy.
- Run a small private beta focused on the three wow moments: Search, selected-text Ask Lima, and dictation into Notes.
- Fix repeated beta complaints and release blockers before adding more headline features.

## Current evidence snapshot

- Swift: 340 tests passed after the AI activity/copy and broad-grant changes; opt-in Zen read acceptance passed.
- Browser companion: 41 JavaScript tests; 11 signing tests; native-helper smoke passed.
- Visual audit: zero failed renders, including compact streaming/Markdown AI fixtures.
- Signed companion: source and metadata verified; private build-asset upload verified by SHA-256 download-back.
- Local model-free and full signed app packages, plus the full-app DMG, verified with the unchanged signed XPI.
- Still pending: reliable live Zen reconnect and action-approval acceptance, live provider/UI-click checks, onboarding/diagnostics/performance/update matrix, and commercial beta. Firefox was waived for this requested deployment, not verified.
- The private build-asset upload and local package rehearsal are not a Lima app release. Public publication remains blocked until the live Zen reconnect and action checks pass.
