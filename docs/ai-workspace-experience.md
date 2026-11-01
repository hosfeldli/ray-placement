# AI workspace experience

## Mission view

The live chat now has a compact mission card. Expand it to see the latest user request, current recorded action and result counts. The Activity sidecar shows the full card and recent steps. A gently moving sparkle pauses for Reduce Motion and inactive tasks.

The card uses the latest user message and only the assistant events after that message. Starting a new request cannot reuse the previous request's actions. Returned tool results, failed actions, approvals and interrupted work remain distinct. There is no invented percentage, speculative plan or claim that returning a tool result completes the user's goal.

## Move between tools

Chat, Browser and Terminal share a small switcher above their content. Switching changes presentation and preserves the existing conversation, browser model and terminal coordinator. Terminal shows a running-session count for the selected conversation. Existing source access and ownership policies remain in effect.

Narrow chat headers separate model selection from the other controls. Response actions use compact icons, accessible names and tooltips, while timestamps stay on one line.

## Extensions and Search

The installed-extensions header is compact, and extension cards use plain content surfaces. Filters fall back to a menu at narrow widths. The expanded command list follows the search query. Each command has a Find in Search button that prepares and opens Search without executing the command. Execution continues through the launcher's normal explicit action path.

## AI shell work

`terminal_execute` takes a shell command or multiline script, an existing absolute working directory, and an optional 1–900 second timeout. It starts a visible, conversation-owned session and returns immediately. Use `terminal_wait` to observe output and verify exit. Starting a command does not report success.

Shell commands may create or edit files, run scripts, use pipelines, build and test under the user's normal filesystem/network access. The command limit is now 64 KiB rather than 4 KiB. The chosen working directory is passed directly to Process rather than interpolated into shell source, is shown in the terminal snapshot, and remains the initial directory for later `terminal_run` calls. Explicit `terminal_set_directory` resets that override to the chosen Project/Scratch subdirectory. Cache and temporary directories remain in the managed session root.

Terminal permissions and exact-call review outside Full Control still apply. Conversation ownership, cancellation, timeouts and output limits remain. The older `run_terminal_command` compatibility tool keeps its existing narrow behavior; the assistant's instructions direct general shell work to `terminal_execute` or reusable Workspace sessions.

## Verification

- 81 focused regression tests passed across terminal execution, activity, mission projection, Search, layout and tool access.
- An integration test created, edited and ran a script in a directory with spaces and an apostrophe, verified output and exit status, and reused the session in the same directory.
- Missing-directory and unapproved requests created no sessions. Scripts larger than the old 4 KiB limit ran successfully; oversized scripts were rejected before launch.
- 28 final offscreen fixtures rendered across both appearances, full/compact mission states, and Chat/Browser/Terminal/Extensions at 420 and 1040 points.
- The build passed. These are local source/build changes; the installed application has not been replaced. A live provider-to-tool journey has not been exercised.
