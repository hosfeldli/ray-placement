# Lima QA MCP

The QA MCP is compiled into the app only when SwiftPM is invoked with
`LIMA_BUILD_QA_MCP=1`. The default release/package manifest does not declare the
QA protocol or MCP executable.

## Build and launch

Use the dedicated QA scripts:

```sh
scripts/package_qa_app.sh
scripts/run_qa_app.sh "build/Lima Test.app"
```

The launch helper supplies both runtime opt-ins:
`LIMA_TEST_MODE=1` and `LIMA_ENABLE_QA_MCP=1`. A QA-compiled app started
without both variables cannot create the control socket. The server stays off
until enabled in **Settings → Advanced → QA MCP**; that preference is restored
on launch only when both runtime opt-ins are present. The panel generates a
stdio MCP client configuration for the bundled executable. QA packaging is
separate from `build/Lima.app` and QA builds do not contact the public updater.

Point an MCP client at:

```text
build/Lima Test.app/Contents/MacOS/LimaQAMCPServer
```

The adapter speaks MCP over stdio and forwards only its fixed, bounded tool
catalog over `/tmp/limaqa-<uid>.sock`. The app creates that Unix-domain socket
with mode `0600`; it never opens a TCP listener.

## Current tool catalog

- System: `lima_status`
- Surfaces: `surface_list`, `surface_open`, `surface_close`
- UI: `ui_inspect`, `ui_find`, `ui_activate`, `ui_set_text`, `ui_press_key`
- State: `app_state`, `tasks_list`, `ai_activity`

UI targets must use centralized Lima semantic accessibility identifiers.
Task/activity projections omit prompt text, tool arguments, note content, and
credentials. This initial vertical slice does not implement fixture seeding,
fault injection, screenshots, expression-based assertions, or state waits yet.
