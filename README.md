# LiamFlow 3.0

LiamFlow is Liam Hosfeld's fast, keyboard-first native macOS workbench. It combines global commands, extensible native forms, Markdown notes, a real developer terminal, a Postman-style API workspace, and local meeting dictation without accounts or analytics.

Text generation has been removed. Writing correction uses deterministic local Python and Harper rules. Dictation is the only model-powered feature and runs locally through Whisper.

## Install

LiamFlow targets Apple-silicon Macs on macOS 13 or later. The release DMG includes a ready-to-install app; building from source requires Swift 6 from Xcode 16 Command Line Tools or newer.

1. Download `LiamFlow.dmg` from the LiamFlow product site or the GitHub release, then open `Install LiamFlow.command` from the disk image.
2. The guided installer SHA-256 verifies the pinned local dictation model, verifies the bundle, and installs `~/Applications/LiamFlow.app` with bundled extensions.
3. Grant Accessibility in **System Settings → Privacy & Security → Accessibility** for selected-text replacement, automatic paste, and window controls.

The first install downloads about 465 MB for dictation. Later installs and self-updates reuse a verified installed copy. No Qwen, CoEdit, or other text-generation model is downloaded or packaged.

Choose **LiamFlow → Uninstall LiamFlow…** to remove the app from within LiamFlow, or double-click `Uninstall LiamFlow.command` from the disk image for the optional data cleanup.

## Main workflow

- Open the launcher with its configurable global shortcut, type to search, and press Return.
- Configure or disable every extension shortcut independently in **Settings → Extensions**.
- Configure launcher, Notes, dictation, dock-left, and dock-right shortcuts in **Settings → General**.
- Regular RayPlacement tools join one native macOS tabbed window by default. Use the standard Window menu or drag a tab to break it into a separate window.
- Background extension work reports compact progress without blocking the launcher.

Version 2.0 introduces a higher-contrast prismatic visual system across every workspace: sharper glass edges, clearer selected states, tighter controls, calmer ambient motion, and reduced-motion support through macOS. Keyboard hints appear only at the point of use.

## Developer Terminal

Developer Terminal is backed by a true local pseudo-terminal through SwiftTerm. It starts an interactive `zsh`, maintains working directory, environment variables, history, and child-process state between commands, and supports ANSI/TUI applications.

- Enter any sequence of commands in the same session.
- Control combinations such as Control-C, Control-D, and Control-Z are sent to the PTY.
- **Option as Meta** is configurable in the terminal toolbar.
- Paste, clear, interrupt, restart, and font controls are available.
- Vim and Nano show a compact bottom overlay with common keys while the program is active.

## API Workspace

Endpoint Tester is a native Postman-style workspace:

- HTTP methods, query parameters, headers, JSON/text/XML bodies, response body/headers/raw views, history, cancellation, and cURL export
- no auth, Bearer, Basic, and API-key auth in either headers or query strings
- Postman collection v2.0/v2.1 imports with nested folders and collection/folder/request auth inheritance
- Postman environment imports, enabled variables, collection variables, and `{{variable}}` resolution
- collection runner with user-selected iteration count and delay, per-request results, and cancellation; RayPlacement imposes no product credit or runner-count cap
- local workspace persistence in Application Support with restrictive file permissions; request secrets are never included in usage logs

## SQL Workspace

SQL Workspace is a native Oracle and MySQL client that uses the installed `sqlplus` or `mysql` command-line client on your Mac. It does not bundle proprietary database drivers. Add named development, staging, and production connections, then save each password to the macOS Keychain; the local workspace file contains only connection metadata and cached schema information.

- Discover all objects visible to the connected account: tables, views, columns and descriptions, primary/foreign-key constraints, indexes, and procedures/functions.
- Drag schema tables into the visual canvas or free-SQL editor. The join panel proposes foreign-key-compatible joins and inserts their exact predicates.
- Use read-only execution for `SELECT`/`WITH` work. Other SQL remains available in Free SQL after an explicit per-run confirmation.
- Export a selected result range into the built-in local document store. Collections are saved locally, can be extended with later exports, and are available from SQL Workspace → Storage.

## Notes and dictation

Notes open in a dedicated resizable window that can join the workspace, become full screen, or dock as a narrow quick-note panel on either side. Pressing the Notes shortcut again closes the Notes window. Notes save locally while typing and can be searched, pinned, favorited, and reordered by those groups.

The editor presents formatted Markdown in place instead of a separate rendered preview. It supports headings, bold, italic, lists, links, code, and native-looking tables. Pasted tabular content is converted into an editable table; table titles and column sorting are supported.

Dictation records durable one-minute audio segments and can continue for hour-plus meetings even if the Notes window closes. A compact speech-level indicator remains visible while recording. Completed segments are transcribed as recording continues, so a final stop has only the remaining queue to process. The local Whisper small.en TinyDiarize build applies bounded room-audio gain, detects pauses for paragraphs, and uses best-effort speaker-turn labels. Settings provide Automatic Metal with CPU fallback, Metal, or CPU compute.

The most-recent-note dictation shortcut opens that note and toggles recording. Local Whisper appends each completed segment during the meeting, while the compact top-screen indicator shows audio levels and progress. The active segment is finished after Stop, and audio remains recoverable until successfully transcribed.

## Writing correction

The bundled Writing Tools extension includes:

- **Paste as Plain Text** — default `Control-Option-V`
- **Check Spelling & Grammar** — default `Control-Option-G`

Writing Check captures the exact current selection through a Copy transaction, immediately restores the previous clipboard when safe, runs the bundled pure-Python spelling pipeline followed by Harper grammar rules, and opens a review. Return or **Replace Selection** returns focus to the source app and replaces the original selection; a clipboard fallback is available if the source app blocks automation.

**Settings → Writing** accepts one preserved term per line for names, acronyms, brands, or domain-specific words that must not be changed. It is not a model prompt and no selected text is sent over the network.

## Other bundled extensions

- **Password Generator** — cryptographically secure local passwords, length 8–128, selected character classes, ambiguous-character exclusion, entropy display, and copy
- **Document Formatter** — a dedicated temporary workspace for EDI, JSON, and XML; pretty/minify, validation, search, EDI delimiter detection and swapping, field inspection, and common transaction/envelope checks
- **Emoji Picker** — searchable emoji paste; default double Command
- **Focused File Launcher** — Finder-backed file/folder selection with a choice of any installed destination app
- **Convert Timezones** — offline daylight-saving-aware conversion
- **Force Quit Application / All Applications** — explicit confirmation; the all-app action always excludes RayPlacement

Formatter is separate from Notes and never appears as a note type.

## Extensions

Extensions live under `~/Library/Application Support/RayPlacement/Extensions/`. A manifest can open resources, copy/paste text, run a reviewed executable, or create a native form and input/output workflow. Schema v2 supports sections, conditional visibility, file and directory pickers, secure fields, dates, sliders, key/value editors, HTTP requests, and executable results.

See [docs/EXTENSIONS.md](docs/EXTENSIONS.md), the JSON [manifest schema](docs/extension-manifest.schema.json), and the [coding-agent authoring guide](docs/EXTENSION_AUTHORING_FOR_AI.md). `Examples/project-tools` is a small working example.

## Performance and usage

Settings provides separate performance scales for Writing, Dictation, and executable Extensions, including explicit **Unbounded**. Beta Dynamic treats the configured value as a ceiling and backs down under Low Power Mode or thermal pressure. Dictation additionally exposes Automatic Metal+CPU fallback, Metal, and CPU compute.

Writing resources are process-based and exit after each correction. Whisper processes completed audio segments and exits after its queue is empty. Extension processes receive thread, numerical-library, and timeout environment limits; Unbounded removes the RayPlacement wall-clock timeout but does not turn third-party code into a sandbox.

**Settings → Usage** shows active tasks, durations, thread counts, input/output sizes, outcomes, and a locally stored diagnostic log. Passwords, auth values, note bodies, selected text, and dictated content are not logged.

## Updates

LiamFlow checks its configured product-site update feed after startup and also offers **Check for Updates** in the menu and Settings. It never installs silently. After confirmation, a visible progress window downloads the compact prebuilt update kit, verifies its GitHub SHA-256, restores or downloads the pinned local dictation model as needed, verifies the new bundle, swaps it atomically, and relaunches. The update preparation uses an ad-hoc local signature—no user-created certificate or trusted signing identity is required. A failed preparation leaves the current app unchanged; a failed swap restores the previous app. Detailed progress remains at `~/Library/Application Support/RayPlacement/Updates/update.log`.

## Build and verify

```sh
swift test
./scripts/package_app.sh
./scripts/verify_app.sh build/RayPlacement.app
```

`scripts/assemble_whisper_model.sh` restores the verified model from an existing RayPlacement app or downloads the exact pinned asset. `scripts/fetch_vendor_assets.sh` prepares only the dictation asset; there is no text-model asset fetch.

Important source areas:

- `Sources/RayPlacement/DeveloperTerminalWindowController.swift` — PTY terminal
- `Sources/RayPlacement/EndpointTesterWindowController.swift` and `Sources/RayPlacementCore/PostmanWorkspace.swift` — API workspace/imports
- `Sources/RayPlacement/NotesWindowController.swift` and `Sources/RayPlacement/NoteDictationService.swift` — notes and meeting dictation
- `Sources/RayPlacement/RuleBasedWritingChecker.swift` — Python + Harper pipeline
- `Sources/RayPlacement/ExtensionFormWindowController.swift` — dynamic extension forms
- `Sources/RayPlacement/WorkspaceWindowCoordinator.swift` — independent, resizable workspaces without native tab bars
