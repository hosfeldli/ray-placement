# Lima 3.4.1

Lima is Liam Hosfeld's fast, keyboard-first native macOS workbench. It combines global commands, extensible native forms, Markdown notes, a real developer terminal, a Postman-style API workspace, and local meeting dictation without accounts or analytics.

Text generation has been removed. Writing correction uses deterministic local Python and Harper rules. Dictation is the only model-powered feature and runs locally through Whisper.

## Install

Lima targets Apple-silicon Macs on macOS 13 or later. The release DMG includes a ready-to-install app; building from source requires Swift 6 from Xcode 16 Command Line Tools or newer.

Version 3.3 adds virtualized, filterable SQL results; full-workspace schema and compatible-join dragging; deeper local and remote SSH file trees; context-aware terminal guidance; and administrator-approved protected-folder updates with cancellation-safe rollback.

Version 3.4 makes the launcher pointer-stable: hovering a result updates its highlight without recentering or scrolling the list. Exact command names rank first, every major native workspace is directly searchable, and keyboard navigation remains the only action that intentionally scrolls selection into view. Compact, Balanced, and Comfortable interface densities now resize launcher rows and workspace presentation live. The bundled themes have clearer workflow-oriented names, workspace window positions persist, active-process notifications show elapsed time, and ambient refraction pauses while local processing is active. Notes can persist custom names for detected transcript speakers and apply them to later dictation segments in that note.

Version 3.4.1 repairs compact self-updates: release packaging now refuses to include the 465 MB dictation model in the update archive, while the installed app preserves or restores its checksum-verified local copy. The updater reports real download size, elapsed time, verification and replacement stages, administrator/signing approval context, and provides Cancel, Retry, Show Log, and DMG recovery actions. A pinned public certificate can be added to the login keychain as a code-signing-only trust root after a one-time macOS approval; no private signing key is distributed.

1. Download `Lima.dmg` from the Lima product site or the GitHub release.
2. Drag `Lima.app` onto the Applications folder shown in the disk image. The app already contains local dictation and bundled extensions.
3. Grant Accessibility in **System Settings → Privacy & Security → Accessibility** for selected-text replacement, automatic paste, and window controls.

The DMG already contains the dictation model (about 465 MB). Compact updates reuse a checksum-verified copy in Application Support, downloading it only if missing or damaged. No Qwen, CoEdit, or other text-generation model is downloaded or packaged. Open the installed copy from Applications, not the mounted disk image.

Run the bundled **Uninstall Lima** extension to remove the app from within Lima. It keeps notes, extensions, and settings unless you choose to remove them separately.

## Main workflow

- Open the launcher with its configurable global shortcut, type to search, and press Return.
- Pointer hover never moves the result list. Arrow-key and page navigation keep the selected command visible without fighting trackpad scrolling.
- Configure or disable every extension shortcut independently in **Settings → Extensions**.
- Configure launcher, Notes, dictation, dock-left, and dock-right shortcuts in **Settings → General**.
- Regular RayPlacement tools join one native macOS tabbed window by default. Use the standard Window menu or drag a tab to break it into a separate window.
- Background extension work reports compact progress without blocking the launcher.

Version 2.0 introduces a higher-contrast prismatic visual system across every workspace: sharper glass edges, clearer selected states, tighter controls, calmer ambient motion, and reduced-motion support through macOS. Keyboard hints appear only at the point of use.

## Developer Terminal

Developer Terminal is backed by a true local pseudo-terminal through SwiftTerm. It starts an interactive `zsh`, maintains working directory, environment variables, history, and child-process state between commands, and supports ANSI/TUI applications.

- Enter any sequence of commands in the same session.
- Control combinations such as Control-C, Control-D, and Control-Z are sent to the PTY.
- **Option as Meta** and terminal-specific font sizing live in the toolbar’s overflow menu.
- Paste, clear, interrupt, restart, and font controls are available.
- Vim and Nano show a compact bottom overlay with common keys while the program is active.
- Files and the command guide share one resizable inspector beside the same shell. Toggle Files with **⌘⇧E**, Guide with **F1 / ⌘⇧H**, and adjust the inspector with **⌘⇧[ / ⌘⇧]**. The shell stays alive when the window is closed and reopened; restarting requires confirmation.
- **⌘⇧L** opens the command shelf. Guide examples, project suggestions, and file paths prepare text here; **Insert** sends one line without executing it. Review the shell input, then press Return. This avoids a competing command runner or accidentally submitting a command to a foreground editor. Control characters and multiline command-shelf submissions are rejected; normal terminal paste retains native bracketed-paste behavior.
- The explorer follows the actual local shell directory, even when a shell does not emit directory notifications. Its bounded 600-entry preview runs off the UI thread, ignores stale refresh results, and does not recursively follow symlinks. Navigate into large folders to inspect deeper contents.
- Local manual output is drained before waiting for completion, avoiding pipe-buffer deadlocks, and cached for the terminal session.

## Text size

**Settings → General → Appearance** provides Compact, Balanced, and Comfortable interface density plus text sizing from **85% to 140%** in 5% steps, with a one-click reset. Both apply live without recreating windows or losing edits. Text scaling covers app-hosted Markdown, table cells, and terminal text; the terminal’s own 9–28pt base size remains separate and is multiplied by the global setting. Native macOS menus and file dialogs keep the system’s text sizing.

New SwiftUI views should use `.limaFont(.system(size: …))` or semantic recipes such as `.limaFont(.caption)`, and host their roots inside `LimaTypographyRoot(content:)`. Native text views should observe `AppTypography.shared.$scale` and update fonts in place. Do not reset a view’s identity to apply typography changes.

For isolated native UI testing, a debug build accepts `--terminal-preview`. This opens only a terminal and sample note/text-size controls; it does not start the launcher, global shortcuts, dictation, or update checks. Use a separate preview bundle identifier to isolate preferences.

### Verified release uploads

The manual **Assemble verified signed DMG** GitHub workflow can assemble `Lima.dmg.part-aa`, `part-ab`, etc. already uploaded to an existing draft. It requires the exact local SHA-256 and part count, verifies the reconstructed DMG and GitHub’s uploaded digest, then removes only those temporary part assets. It cannot publish a release and refuses published releases. Its repository `contents: write` permission is used for draft release asset upload/deletion; final publication remains a separate reviewed step.

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
- Oracle column discovery runs in owner-specific batches of up to 25 tables instead of one unbounded catalog scan. A timed-out batch is retried in smaller halves, down to a single table, with a 120-second deadline per query. Progress identifies the schema, current table batch, and completed work; discovered metadata appears incrementally and is saved as **Partial schema** if a later query fails. Other stages read tables/views, indexes, constraints, relationships, and procedures. SQLPlus MARKUP CSV (12.2 or newer) preserves quoted/multiline metadata, including LONG column defaults, and output is drained continuously.
- In **Edit connection → Discovery schemas**, optionally enter exact Oracle owner names separated by commas, or choose **My schema**. Empty means every accessible schema. The filter also limits indexes, constraints, relationships, and procedures; MySQL remains limited to its selected database. Broad accounts can still take longer, but completed column batches are no longer discarded by a later timeout.
- Drag schema tables into the visual canvas or free-SQL editor. The join panel proposes foreign-key-compatible joins and inserts their exact predicates.
- SQL Workspace caches each connection’s password in memory for the current app session after its first Keychain read. **Manage connections → Lock credential session** clears the cache; sleep, user-session deactivation, and workspace shutdown also clear it. Passwords are never part of the saved block flows. This removes repeated Keychain prompts, not the underlying command-line client’s per-query connection setup.
- The schema browser puts exact table-name/qualified-name matches first, then prefixes, substring matches, and column matches. Its **Owner** picker filters tables, views, and procedures independently of discovery scope.
- **Query blocks** provides a compact connected flow: source tables, SELECT/DISTINCT, INNER/LEFT/RIGHT/FULL/CROSS joins with editable conditions, nested AND/OR/NOT filters, GROUP BY, COUNT/SUM/AVG/MIN/MAX, HAVING, sorting, and row limits. Text/number/column values, IN lists (one value per line), ranges, NULL checks, LIKE, and custom SQL conditions are supported. Drag palette blocks into the flow; reorder joins, aggregates, sorts, and sibling filters by dragging. SQL clause categories stay in valid SQL order. Free SQL remains available for arbitrary statements and advanced dialect-specific syntax.
- The generated SQL stays visible before execution. Incomplete blocks, invalid numeric values, invalid grouping, duplicate joins, and unsupported MySQL FULL OUTER joins report actionable errors. **Save query blocks** stores a separate flow per connection; switching connections restores that connection’s flow. Removing a source asks before resetting its query blocks.
- Query blocks have collapsible, plain-language headers, quieter surfaces, and on-demand explanations. The wrapping palette keeps every block type visible at narrow widths. Join types explain which rows they retain; incomplete flows disable Run with the exact issue shown above the canvas. Collapse transitions respect Reduce Motion.
- Schema catalogs are indexed once per metadata revision; exact-match ranked searches run off the main UI thread with a short typing debounce and stale-result cancellation. Column suggestions are cached instead of rebuilt for every block edit. **⌘F** focuses schema search, **⌘⌥1 / ⌘⌥2** toggle the schema/details panels, and **⌘Return** runs a valid canvas query.
- Use read-only execution for `SELECT`/`WITH` work. Other SQL remains available in Free SQL after an explicit per-run confirmation.
- Export a selected result range into the built-in local document store. Collections are saved locally, can be extended with later exports, and are available from SQL Workspace → Storage.

## Notes and dictation

Notes open in a dedicated resizable window that can join the workspace, become full screen, or dock as a narrow quick-note panel on either side. Pressing the Notes shortcut again closes the Notes window. Notes save locally while typing and can be searched, pinned, favorited, and reordered by those groups.

The editor presents formatted Markdown in place instead of a separate rendered preview. It supports headings, bold, italic, lists, links, code, and native-looking tables. Pasted tabular content is converted into an editable table; table titles and column sorting are supported.

Dictation records durable one-minute audio segments and can continue for hour-plus meetings even if the Notes window closes. A compact speech-level indicator remains visible while recording. Completed segments are transcribed as recording continues, so a final stop has only the remaining queue to process. The local Whisper small.en TinyDiarize build applies bounded room-audio gain, detects pauses for paragraphs, and uses best-effort speaker-turn labels. Settings provide Automatic Metal with CPU fallback, Metal, or CPU compute.

For speaker-aware transcripts, use the note’s **More → Name Transcript Speakers** action. The names are stored with that local note, update existing speaker labels, and are applied automatically to new dictation segments appended to it.

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

Lima checks its configured product-site update feed after startup and also offers **Check for Updates** in the menu and Settings. It never installs silently. After confirmation, the updater verifies the archive SHA-256 and prebuilt app version/build/signature, preserves the dictation model outside the app, and replaces the exact running app path using a staged bundle and rollback backup. It never redirects an installation in `/Applications` to `~/Applications`. Relaunch uses the exact installed path, and the new process checks a version/build/path receipt before reporting success. Settings → About → Update details can reveal the running copy in Finder.

No compiler or local signing key is required on another Mac. The downloaded signature is preserved; an existing local signing identity is reused only when it matches the currently installed app. On a fresh Mac, Lima verifies the bundled public certificate against its pinned SHA-256 fingerprint and the incoming app signature before asking macOS to add that certificate to the login keychain as a code-signing-only trust root. No private key is distributed. This one-time approval gives subsequent builds a stable identity for Accessibility; these builds are not Apple-notarized Developer ID distributions.

When the app folder cannot create a staging directory, the updater requests one-time administrator approval through macOS (the system prompt may identify its tool as **osascript**). It first verifies the incoming app against the installed signing identity, then stages a root-owned, non-writable copy before telling Lima to close. Declining approval leaves the current app running. No password is read, stored, or logged by Lima; no privileged daemon is installed, folder permissions are not loosened, and relaunch/model/extension work still runs as the signed-in user. Disk-image launches remain unsupported; drag the app into Applications first. Ad-hoc or unrelated signing identities require installing the official DMG once with Finder instead of weakening signature checks.

Failed swaps restore the previous bundle; successful updates keep a recovery copy in a `.lima-install.*` folder beside the app. The exact path appears in `~/Library/Application Support/RayPlacement/Updates/update.log`; protected-folder approval details are in `administrator-update.log` there. Administrator-owned recovery copies may require Finder approval to remove. MDM restrictions or a missing administrator account are not bypassed. The optional `Install Lima.command` installs a prebuilt app to `/Applications/Lima.app` (or an explicit destination); the old installer name forwards to it and no longer builds or installs RayPlacement.

## Build and verify

```sh
swift test
./scripts/test_lima_installer.sh
/bin/zsh scripts/test_approved_lima_update.sh
# Optional local tests with the existing development signing identity:
LIMA_TEST_STABLE_SIGNING=1 /bin/zsh scripts/test_approved_lima_update.sh
./scripts/package_liamflow_app.sh
./scripts/verify_liamflow_app.sh build/Lima.app
```

`scripts/assemble_whisper_model.sh` restores the verified model from an existing RayPlacement app or downloads the exact pinned asset. `scripts/fetch_vendor_assets.sh` prepares only the dictation asset; there is no text-model asset fetch.

Important source areas:

- `Sources/RayPlacement/DeveloperTerminalWindowController.swift` — PTY terminal
- `Sources/RayPlacement/EndpointTesterWindowController.swift` and `Sources/RayPlacementCore/PostmanWorkspace.swift` — API workspace/imports
- `Sources/RayPlacement/NotesWindowController.swift` and `Sources/RayPlacement/NoteDictationService.swift` — notes and meeting dictation
- `Sources/RayPlacement/RuleBasedWritingChecker.swift` — Python + Harper pipeline
- `Sources/RayPlacement/ExtensionFormWindowController.swift` — dynamic extension forms
- `Sources/RayPlacement/WorkspaceWindowCoordinator.swift` — independent, resizable workspaces without native tab bars
