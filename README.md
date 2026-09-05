# Lima 3.12.0

Lima is Liam Hosfeld's fast, keyboard-first native macOS workbench. It combines global commands, extensible native forms, Markdown notes, a real developer terminal, a Postman-style API workspace, and private local dictation conversations without accounts or analytics.

Text generation has been removed. Writing correction uses deterministic local Python and Harper rules. Dictation is the only model-powered feature and runs locally through Whisper.

## Install

Lima targets Apple-silicon Macs on macOS 13 or later. The release DMG includes a ready-to-install app; building from source requires Swift 6 from Xcode 16 Command Line Tools or newer.

The 3.12.0 release repairs compact self-updates: release packaging now refuses to include the 465 MB dictation model in the update archive, while the installed app preserves or restores its checksum-verified local copy. The updater reports real download size, elapsed time, verification and replacement stages, administrator/signing approval context, and provides Cancel, Retry, Show Log, and DMG recovery actions. A pinned public certificate can be added to the login keychain as a code-signing-only trust root after a one-time macOS approval; no private signing key is distributed.

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
- Bind accessory mouse buttons independently in **Settings → General**, including Previous/Next Desktop (Control–Left/Right), Mission Control, Notes, and Developer Terminal.
- Lima tools join one native macOS workspace by default and can be broken into separate windows when needed.
- Background extension work reports compact progress without blocking the launcher.

Version 2.0 introduces a higher-contrast prismatic visual system across every workspace: sharper glass edges, clearer selected states, tighter controls, calmer ambient motion, and reduced-motion support through macOS. Keyboard hints appear only at the point of use.

## Developer Terminal

Developer Terminal is always available from the launcher, direct actions, and accessory-button bindings. Its global hotkey remains independently configurable in **Settings → General**. It is backed by a true local pseudo-terminal through SwiftTerm. It starts an interactive `zsh`, maintains working directory, environment variables, history, and child-process state between commands, and supports ANSI/TUI applications.

- Enter any sequence of commands in the same session.
- Control combinations such as Control-C, Control-D, and Control-Z are sent to the PTY.
- The terminal surface intentionally contains only the interactive shell.
- Use the shell’s native keyboard controls, including Control-C, Control-L, Vim, Nano, and shell completion. The terminal remains a persistent local `zsh` session while the launcher is open.

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
- collection runner with user-selected iteration count and delay, per-request results, and cancellation; Lima imposes no product credit or runner-count cap
- local workspace persistence in Application Support with restrictive file permissions; request secrets are never included in usage logs

## Notes and dictation

Notes open in a dedicated resizable window that can join the workspace, become full screen, or dock as a narrow quick-note panel on either side. Notes save locally while typing and can be searched, pinned, favorited, and reordered by those groups.

The editor presents formatted Markdown in place instead of a separate rendered preview. It supports headings, bold, italic, links, code, managed image attachments, native bar/line chart blocks, interactive task checkboxes with completion progress, and native-looking tables. Pasted images are copied into Lima's local Note Assets folder; pasted tabular content becomes an editable table with titles and column sorting.

Dictation is a separate workflow with its own persistent conversations. It never appends to, modifies, or selects a Markdown Note. Each conversation is bounded to 200,000 characters and the store retains up to 100 conversations. The transcript remains available in the Dictation tab even after the Notes window closes.

Dictation records short local audio segments while recording. Completed segments are transcribed as recording continues, and a final stop processes the remaining queue.

The dictation lifecycle is explicit: **Idle**, **Recording**, **Paused**, **Stopping**, **Transcribing**, **Completed**, and **Failed**. Recording exposes separate Pause/Resume and Stop & Transcribe actions; completed transcripts can be edited, failed work can be retried, and destructive deletion requires confirmation. Audio is kept locally only while it is needed; failed or canceled work preserves unfinished audio for **Retry Transcription**. Local Whisper uses the bundled small.en TinyDiarize runtime, with Automatic Metal/CPU fallback, Metal, or CPU compute options. Apple on-device speech recognition is also supported when available.

The compact activity shelf is repositioned along the bottom of the visible screen so it does not cover application chrome. It shows dictation state and audio levels without taking keyboard focus. It also provides optional now-playing metadata and controls for supported local media players. Reduce Motion and Reduce Transparency settings are honored by the shelf and workspace animations.

## Writing correction

The bundled Writing Tools extension includes:

- **Paste as Plain Text** — default `Control-Option-V`
- **Check Spelling & Grammar** — default `Control-Option-G`

Writing Check captures the exact current selection through a Copy transaction, immediately restores the previous clipboard when safe, runs the bundled pure-Python spelling pipeline followed by Harper grammar rules, and opens a review. Return or **Replace Selection** returns focus to the source app and replaces the original selection; a clipboard fallback is available if the source app blocks automation.

**Settings → Writing** accepts one preserved term per line for names, acronyms, brands, or domain-specific words that must not be changed. It is not a model prompt and no selected text is sent over the network.

## Other bundled extensions

- **Password Generator** — cryptographically secure local passwords, length 8–128, selected character classes, ambiguous-character exclusion, entropy display, and copy
- **Document Formatter** — a dedicated temporary workspace for EDI, JSON, and XML; pretty/minify, validation, search, EDI delimiter detection and swapping, field inspection, and common transaction/envelope checks
- **Emoji Picker** — the complete paged Unicode keyboard set with ranked aliases, fast bounded lookup, focus-aware paste, and automatic clipboard restoration; default double Command
- **Focused File Launcher** — Finder-backed file/folder selection with a choice of any installed destination app
- **Convert Timezones** — offline daylight-saving-aware conversion
- **Force Quit Application / All Applications** — explicit confirmation; the all-app action always excludes Lima

Formatter is separate from Notes and never appears as a note type.

## Extensions

Extensions live under `~/Library/Application Support/RayPlacement/Extensions/`. A manifest can open resources, copy/paste text, run a reviewed executable, or create a native form and input/output workflow. Schema v2 supports sections, conditional visibility, file and directory pickers, secure fields, dates, sliders, key/value editors, HTTP requests, and executable results.

See [docs/EXTENSIONS.md](docs/EXTENSIONS.md), the JSON [manifest schema](docs/extension-manifest.schema.json), and the [coding-agent authoring guide](docs/EXTENSION_AUTHORING_FOR_AI.md). `Examples/project-tools` is a small working example.

## Performance and usage

Settings provides separate performance scales for Writing, Dictation, and executable Extensions, including explicit **Unbounded**. Beta Dynamic treats the configured value as a ceiling and backs down under Low Power Mode or thermal pressure. Dictation additionally exposes Automatic Metal+CPU fallback, Metal, and CPU compute.

Writing resources are process-based and exit after each correction. Whisper processes completed audio segments and exits after its queue is empty. Extension processes receive thread, numerical-library, and timeout environment limits; Unbounded removes the Lima wall-clock timeout but does not turn third-party code into a sandbox.

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

`scripts/assemble_whisper_model.sh` restores the verified model from an existing Lima app or downloads the exact pinned asset. `scripts/fetch_vendor_assets.sh` prepares only the dictation asset; there is no text-model asset fetch.

Important source areas:

- `Sources/RayPlacement/DeveloperTerminalWindowController.swift` — PTY terminal
- `Sources/RayPlacement/EndpointTesterWindowController.swift` and `Sources/RayPlacementCore/PostmanWorkspace.swift` — API workspace/imports
- `Sources/RayPlacement/NotesWindowController.swift`, `Sources/RayPlacement/DictationConversationStore.swift`, and `Sources/RayPlacement/NoteDictationService.swift` — Notes and separate dictation conversations
- `Sources/RayPlacement/RuleBasedWritingChecker.swift` — Python + Harper pipeline
- `Sources/RayPlacement/ExtensionFormWindowController.swift` — dynamic extension forms
- `Sources/RayPlacement/WorkspaceWindowCoordinator.swift` — independent, resizable workspaces without native tab bars
