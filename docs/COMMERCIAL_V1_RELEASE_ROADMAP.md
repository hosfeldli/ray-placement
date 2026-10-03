# Lima commercial v1 release roadmap

Status: October 2, 2026. This is a release gate, not a claim that the app is ready to sell.

## Product contract

- **Search** is transient, compact, keyboard-first, and disappears after action.
- **Workspace** persists Notes, AI, Context, Clipboard, Workflows, and optional history.
- **HUDs** briefly report capture, dictation, replacement, workflow, and AI outcomes.
- Default navigation exposes Home, Notes, AI, Context, then Clipboard, Workflows, Extensions under Tools. Grammar, Transcripts, Formatter, Terminal, passwords, and similar utilities stay available through Search/commands without crowding the rail.
- Home resumes work (Continue, Recent, Pinned) instead of cataloging features.
- AI shows recorded completed actions and the current action. It never schedules hypothetical tool calls visually. A model-authored plan, when present, must be labeled tentative and allowed to change.
- Browser v1 defaults to reading and bounded open/focus/navigate. Click, type, and submit stay off by default behind Advanced → Experimental and require individual Lima approval. Local writes, file creation, code execution, and terminal actions remain separately policy-controlled and bounded.

## Release stages and exit criteria

### 1. Surface and primary-workflow finish

**Implemented / automated evidence:** simplified rail and resume-oriented Home; compact Search changes; shared full/side AI message rendering; deterministic visual audit.

**Exit criteria still requiring hands-on evidence:**
- Verify Search invocation, keyboard results, action dispatch, and dismissal on a clean install.
- Audit major Workspace modules and HUDs in light/dark, compact/full widths, reduced motion, and accessibility sizes. Remove inconsistent row, border, typography, and inspector patterns.
- Exercise selected text → Capture → Save to Note / Add Context / Ask Lima without leaving the source app.
- Exercise Notes editing, checklists, Markdown, undo/redo, dictation insertion, autosave, restart persistence, and instant note search.
- Exercise Context add/search/remove and sequential Workflows with stop-on-failure, continue-on-failure, cancellation, and visible outcomes.

### 2. AI reliability and truthful activity

**Implemented / automated evidence:** response and code-block copy use one exact-text pasteboard path with feedback; live activity is projected from recorded events, expands while working, and collapses after completion. Denied requests do not count as executed actions; stopped work does not read as Done. The latest Swift run passed 333 tests, and the visual audit reported zero failed renders.

**Exit criteria still requiring hands-on evidence:**
- Click response and code-block Copy in both full and compact AI windows; paste into another app and compare exact whitespace/newlines.
- Test live provider send, stream, Stop, retry, timeout, malformed response, approval pause/denial, and partial-answer preservation. The app must remain responsive; cancellation must be prompt.
- Confirm every user-facing error is actionable, with technical detail behind disclosure, and that provider/tool configuration recedes after setup.
- Confirm no pending or imagined tool step is displayed as a completed or scheduled action.

### 3. Browser Bridge 1.3.0

**Verified locally:** the downloaded 1.3.0 XPI matches the reviewed companion source and includes Mozilla signature metadata. SHA-256 is `6d4c4f345fc7a8102a7a43b37807c5e97bfd4bd7752f210563c76a94d8a3c6b2`. The unchanged bytes are pinned in `Packaging/build-assets.json`, staged in the ignored local vendor path, and uploaded to the private versioned GCS build-asset object; a download-back SHA-256 matched. The hosted workflow points to 1.3.0. Browser JS (41), signing (11), native-host smoke, and relevant Swift tests passed.

**Live Zen evidence:** the signed 1.3.0 XPI is installed and active. A live service test verified its broad grant and interaction capability, filtered a broad-only `example.com` tab with Lima's experiment off, read that public page with the experiment on, and filtered it again after disabling. A later test could not reconnect after the Lima test app restarted; no navigation approval was reached. Firefox live testing was waived for this requested deployment, but Firefox behavior is not verified.

**Not yet certified:** local packaging does not establish the full browser interaction matrix. Before public release, restore and verify reliable Zen reconnection, then test:
- version and capability advertisement, native-helper connection, exact-site grant, tab listing, selection/page read;
- open, batch-open, focus, navigate, expected-URL mismatch, cross-site denial, revocation, and Stop;
- Experimental click/type/submit only when explicitly enabled, with individual Lima approval, safe targets, and denial/cancel behavior;
- restart persistence and multiple profiles/sessions; test Firefox separately before claiming Firefox support.

Do not publish a bridge-enabled app or mark browser trust/live acceptance complete until that matrix passes. An earlier companion's results do not certify 1.3.0.

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
- Run a small end-to-end regression suite for Search, Notes, Dictation, AI, Clipboard, Context, Workflows, and Browser, plus visual snapshots.
- Build both model-free and full app variants with the same pinned signed XPI; verify the embedded bytes and app/DMG signatures. Do not alter a signed XPI or overwrite a published release.
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
