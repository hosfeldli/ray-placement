# Workspace, Settings and interrupted-chat repairs

## Behavior

- Search dismisses before Settings is presented on the next main-actor turn. Settings starts at 1060 × 760, shares the view's 900 × 620 minimum, and disables automatic hosting-view size feedback. The retained controller supports repeated open/close cycles.
- Commands renders cached catalog entries, filter counts and filtered rows. Extension manifest reads, adapter discovery and schema serialization run on a coalesced refresh after catalog/settings changes, rather than repeatedly during body evaluation or query typing.
- Chat's terminal monitor is hidden when the full Terminal is displayed beside it. Browser and Terminal can also be shown together in a resizable split, horizontally on wide panes and vertically on smaller panes, with Chat retained in its existing sidecar. Processes and browser tabs remain owned by their existing stores.
- The Work menu reveals Browser tabs, the current conversation's terminals, and temporary reports. Terminal gains an AI instruction composer, shared task progress and named navigation/control keys for interactive programs. AI instructions remain distinct from shell input; unsent Chat drafts are preserved.
- The activity shelf omits AI task segments while an Assistant/Browser/Terminal workspace or Chat sidecar is actually visible. Recording, music, other tasks and their controls remain available. Visibility tracks native windows, including closing/minimizing; mounting a hidden view alone is insufficient. Segment cards have consistent backgrounds and clearer secondary text.
- General Settings includes a dedicated Capture & Screen Reader shortcut group. It uses the existing registration, toggles and conflict handling. Region selection has an accent outline, corner handles, dimensions and a rounded instruction badge.

## Interrupted Responses requests

A first user-message request with a previous response reference may rebuild once from the bounded saved transcript when an HTTP 400/404 explicitly rejects that reference or reports a missing tool result. The rejected request has not generated output or executed local actions. The replacement removes the previous reference and does not replay tool outputs. A second failure is surfaced normally; unrelated schema, model, reasoning, authentication and rate-limit errors do not use this repair.

Failed-turn retry branches also start from durable messages without carrying an interrupted response reference. Ordinary edits and model-switch context behavior retain their existing contracts. Recovery never treats an uncertain external action as safe to repeat. No production error payload was provided, so this repair targets the observed failure class without claiming every HTTP 400 shares one cause.

## Structured data collection and reports

`request_user_input` now supports `kind: form` with 1–12 independently labeled fields: text, email, number, ISO date, 24-hour time, select and multiline. Known values can be prefilled. Required fields, dates, times, email addresses and selections validate before submission. Answers return as `field_values` to the paused run. Existing persisted questions continue decoding. Secret/password/payment prompts still use the existing secure handoff instead of this form. Supplying booking details does not authorize a final external commitment.

`workspace_report` creates, lists, reads and opens reports scoped to the current chat. Each report is a real local webpage with escaped text, a restrictive Content Security Policy, JavaScript disabled and a nonpersistent WebKit store. It cannot fetch remote content or submit forms. Reports remain available until Lima quits, with at most eight per chat and 24 overall. The user can reopen them from Work while other surfaces continue running. Existing installs receive this tool once; subsequent explicit disable choices remain respected.

## Verification and limits

Regression coverage includes native Settings open/close/reopen and Search-to-Settings handoff, field validation and persistence, report escaping/ownership/expiry, shelf filtering, real PTY key input, and mocked HTTP recovery. The HTTP fixture verifies successful recovery, a two-request maximum and no retries for unrelated 400s without contacting a real provider.

The visual audit covers reservation forms, the Terminal composer, rail and capture settings across light/dark appearances, narrow/wide widths and enlarged text. No personal Messages, live booking submission, microphone recording, API billing or real user terminal session is needed for these checks.

The Terminal uses Lima's existing project, shell, file, process, server and provider integrations. This is not a claim of complete feature parity with every version of Claude Code or Codex. OS permissions, provider capabilities and Lima's current tool-access choices continue to apply. Temporary reports are not hosted websites, and they do not survive quitting Lima.

Validation completed on November 2, 2026: all 827 tests in the full regression run passed. Eleven final focused checks also passed after the parallel-pane integration, including a real WebKit report snapshot. The final visual audit produced 26 successful renders; no live API or reservation transaction was used.
