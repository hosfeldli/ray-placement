# RayPlacement

RayPlacement is a focused, native, keyboard-first macOS launcher inspired by the standard command-launching side of Raycast. It has no analytics or account. Its optional writing models, Markdown notes, and note dictation all stay on this Mac.

## Use it

1. Double-click `Install RayPlacement.command`. It verifies the bundled Qwen assets, repairs missing Git LFS files from pinned official downloads when needed, creates a stable local signing identity with your consent, builds and signs for this Mac, checks the resulting bundle, and installs the app and bundled extensions. A source ZIP without Git LFS may download about 1.8 GB on first install.
2. Press **Option-Space** from any app to show or hide it.
3. Type an app, command, or calculation and press **Return**.
4. Open **RayPlacement Settings** to change shortcuts, choose performance limits, check Accessibility status, enable launch at login, or opt in to local clipboard history.

To remove the app, double-click `Uninstall RayPlacement.command`. It removes the login item and moves the app to Trash. Notes, extensions, preferences, and the per-Mac signing identity are preserved unless you separately confirm their removal.

RayPlacement also lives in the menu bar. Clipboard history is off by default and, if enabled, stores text locally in `~/Library/Application Support/RayPlacement`.

If Raycast is still running with Option-Space assigned, disable or change its shortcut so both launchers do not respond together.

### First setup on another Mac

RayPlacement currently targets Apple-silicon Macs running macOS 13 or later. Install Swift 6 from Xcode 16 Command Line Tools or newer, then double-click `Install RayPlacement.command`. Git LFS is recommended for a clone but is no longer required for a downloaded source ZIP: the installer detects pointer stubs or corrupt files and retrieves the exact pinned Qwen model and llama.cpp runtime from their official releases. Every local, reconstructed, or downloaded asset is checked against its expected SHA-256 before use. The installer does not reuse or copy a signing key from another computer. It explains the local trust change, asks before making it, creates a private key that stays on that Mac, rebuilds RayPlacement locally, verifies the bundled Qwen model, and installs to `~/Applications/RayPlacement.app`.

After the first install, add that exact app once in **System Settings → Privacy & Security → Accessibility**. Later installs from the same folder reuse the same local identity, so the permission survives rebuilds. A Developer ID certificate and notarization would still be required to distribute a standalone prebuilt app that does not need local build tools.

## Included features

- Application search and launch from the standard macOS app folders
- Spotlight-backed file search
- Calculator results directly in search
- Optional local text clipboard history
- Left/right/top/bottom half, maximize, and center window commands
- Lock, sleep, and screen saver commands
- Menu-bar controls and launch-at-login setting
- Configurable global activation shortcut
- Configurable global shortcuts for opening Notes, docking a Quick Note, and starting or stopping note dictation
- Per-extension global command hotkeys, configurable in **Settings → Extensions**
- JSON extensions for URLs, files, apps, copy/paste actions, and local executable scripts
- Included local Writing Tools extension with plain-text paste and model-only Qwen grammar correction
- Included VS Code extension with an interactive Spotlight search for opening any indexed file or directory
- Included Document Formatter extension with a temporary Notes workspace for EDI, JSON, and XML; it supports file open/save, search, pretty/minified output, structure inspection, EDI delimiter conversion and field analysis, deterministic validation, and reviewable AI correction proposals
- A compact Markdown Notes workspace with local autosave, search, separate pinned and favorite organization, a collapsible list, left/right Quick Note docks, and a distraction-free focus mode
- On-demand Qwen note summaries with review, copy, and insert-at-top actions
- Batch note dictation: it records only after you press Dictate, stops before transcription, requires on-device recognition, and deletes the temporary audio
- Independent six-level performance sliders for writing models, dictation, and executable extensions—including an explicit Unbounded mode—plus an opt-in Beta Dynamic mode
- A private Usage settings tab with live tasks, effective model/thread/scale details, daily totals, bounded local history, Reveal Log, and Clear Log controls; content and prompts are never logged
- Per-task local model assignment, with the bundled Qwen3 1.7B Balanced model plus SHA-256-verified optional [Qwen3 0.6B Fast](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF) and [Qwen3 4B Quality](https://huggingface.co/Qwen/Qwen3-4B-GGUF) downloads from the official Qwen repositories
- Clear Working, Done, and Error states, stage-by-stage writing progress, keyboard action labels, and brief completion confirmations
- A fast, offline two-column timezone converter plus confirmed single-app and all-app Force Quit controls (RayPlacement is always excluded)
- Startup GitHub Release checks with a user-confirmed, SHA-256-verified, locally signed self-update path
- Keyboard navigation with arrows or Control-P/Control-N, Return, Escape, Command-1 through Command-9, and Command-comma

Window changes, automatic paste, and the Lock Screen command request macOS Accessibility permission only when used. The launcher hotkey itself needs no special permission.

## Notes and dictation

Run **RayPlacement Notes** from the launcher, choose **Notes…** in the menu bar, or use the configurable **Open Notes** shortcut in **Settings → General**. **Quick Note Sidebar** has its own configurable global shortcut and pins the most recent note to either screen edge beside the current app. The compact header can move the dock, restore the full workspace, hide the note list, or enter a screen-filling focus mode; the prior size and position are restored when focus mode ends. Notes are saved as local Markdown data in `~/Library/Application Support/RayPlacement/notes.json`. There is no separate source/preview split: headings, emphasis, links, lists, tasks, quotes, inline code, and fenced code blocks are styled directly inside the editable Markdown document. Markdown syntax remains portable and visible in a muted style. Command-B, Command-I, and Command-K wrap the current selection, and Return continues lists and task lists. Formatting is debounced so typing stays responsive.

Choose **Summarize** in a note to run the bundled Qwen3 1.7B model on demand. Long notes are divided into bounded sections and reduced into a final Markdown summary; only one bundled model job can run at a time. The result opens for review and can be copied or inserted at the top of the original note. It uses **Settings → Performance → Writing**, stays CPU-only, sends no note content over the network, and exits when finished or cancelled.

Dictation is deliberately not live. Press **Dictate**, speak, then choose **Stop**. The configurable dictation shortcut opens the most recently edited note and starts recording; press it again to stop and begin transcription. Closing the Notes window does not stop the recording: a compact speech-level panel stays centered above the Dock with elapsed time, quiet-speech feedback, the destination note, and Stop/Cancel controls. Pressing the Notes shortcut again toggles the Notes window without stopping an active recording. If recording reaches its configured limit while Notes is closed, RayPlacement still transcribes it into the note that started the session. RayPlacement records high-quality 48 kHz mono AAC at 96 kbps to retain more distant meeting-room speech, then asks Apple's Speech framework for an on-device-only transcription after recording has stopped. Long meetings are split into 45-second audio segments and transcribed sequentially, so a full recording is never expanded into memory at once. A failed segment is retried once and then represented by a timestamped marker instead of silently losing that part of the meeting. If the current language does not support on-device recognition, RayPlacement stops with an error instead of using a network service. Temporary recording and segment files are deleted after completion, cancellation, or failure. A 60-minute recording is approximately 43 MB.

## Performance controls

**Settings → Performance** has separate sliders for Writing, Dictation, and AI-capable Extensions. Each slider ranges from **Eco** through **Unbounded**. **Beta Dynamic Performance** turns those slider values into ceilings: RayPlacement chooses the fastest safe level under each ceiling while the Mac is cool, and automatically backs down for Low Power Mode or elevated thermal pressure. Dynamic mode never chooses Unbounded on its own.

| Scale | Writing | Dictation | Executable extensions |
| --- | --- | --- | --- |
| Eco | 1 background CPU thread; 90-second limit; 256-token summaries | 15-minute meeting; 90 seconds per transcription segment | background priority; cooperative 1-thread limit; 60-second hard timeout |
| Balanced | 2 utility CPU threads; 120-second limit; 384-token summaries | 30-minute meeting; 120 seconds per segment | utility priority; cooperative 2-thread limit; 180-second hard timeout |
| High | 4 foreground CPU threads; 180-second limit; 512-token summaries | 60-minute meeting; 180 seconds per segment | foreground priority; cooperative 4-thread limit; 600-second hard timeout |
| Turbo | Up to 6 foreground CPU threads; 300-second limit; 768-token summaries | 60-minute meeting; 300 seconds per segment | foreground priority; up to 6 cooperative threads; 1,200-second hard timeout |
| Maximum | Up to 12 CPU threads, never more than the Mac exposes; 600-second limit; 1,024-token summaries | 60-minute meeting; 600 seconds per segment | foreground priority; up to 12 cooperative threads; 3,600-second hard timeout |
| Unbounded | Every logical CPU exposed by macOS; no wall-clock timeout; 2,048-token summaries | 60-minute recording; no per-segment timeout | highest process priority; every logical CPU supplied cooperatively; no RayPlacement wall-clock timeout |

Qwen is CPU-only, never uses the GPU, launches only for a requested grammar check, summary, or formatter proposal, and exits when the job completes or times out. Memory depends on the selected model: Fast is about 639 MB on disk, Balanced about 1.8 GB, and Quality about 2.5 GB. Apple controls the internal scheduling of its on-device speech recognizer, so the dictation scale bounds meeting duration and each sequential segment rather than claiming an exact CPU-thread cap. RayPlacement enforces extension priority, output size, and wall-clock time except when the user explicitly chooses Unbounded; it also supplies common AI thread-limit environment variables, but an untrusted third-party executable can ignore those cooperative variables.

**Settings → Usage** makes this work visible without adding analytics. It shows active local tasks and their elapsed time, model, effective scale, and thread count; keeps a bounded history of durations, character counts, and success/failure; and can reveal or clear `~/Library/Application Support/RayPlacement/Usage/usage-log.json`. Selected text, note contents, document data, prompts, and model output are not written to this log.

## Accessibility that survives rebuilds

**Settings → General → Accessibility** shows whether access is working, opens the correct System Settings pane, and reveals the exact running app so the correct bundle can be added. For local development, run `./scripts/setup_local_signing.sh` once before packaging. It creates a dedicated, local-only private signing key in `~/Library/Application Support/RayPlacement/Signing` and adds only its public certificate to the login keychain with a code-signing trust policy; no certificate or key is uploaded. Builds made with that identity keep the same macOS identity, so Accessibility approval survives future local rebuilds. Anyone who obtains that private key could sign another app as this local identity, so protect the account and do not share the signing folder. After installing the first stably signed build, remove any stale RayPlacement entries from Accessibility, add `~/Applications/RayPlacement.app` once, enable it, and relaunch RayPlacement.

## Add functionality

Choose **Open Extensions Folder** in the launcher and add a folder containing `manifest.json`. The complete format is in [docs/EXTENSIONS.md](docs/EXTENSIONS.md), [docs/EXTENSION_AUTHORING_FOR_AI.md](docs/EXTENSION_AUTHORING_FOR_AI.md) gives future AI agents an exact build-and-verification workflow, and [Examples/project-tools](Examples/project-tools) is a working example.

The included [Extensions/writing-tools](Extensions/writing-tools) extension adds **Paste as Plain Text** (`Control-Option-V`) and **Check Spelling & Grammar** (`Control-Option-G`). Grammar correction goes directly to the local Qwen model assigned in **Settings → Writing** and falls back to the bundled Qwen3 1.7B Q8 model if an optional model is unavailable. No Harper, NSSpellChecker, or deterministic grammar pass changes the text before or after Qwen. The same settings page includes persistent correction instructions for protected names and terms, capitalization, dialect, tone, and preferred style.

[Extensions/document-formatter](Extensions/document-formatter) adds **EDI / JSON / XML Formatter**. It opens as a special temporary item in the Notes sidebar and is discarded when the Notes window closes. JSON and XML can be validated, pretty-printed, minified, searched, and structurally inspected. EDI detects element, component, and segment delimiters; can rewrite segment endings; breaks every segment and field into inspectable paths; and performs basic envelope, control-number, segment-count, and 204/210/214/990/997 checks. **AI Fix** uses the selected local Formatter model and always presents a reviewable full-document proposal before applying it.

Writing checks snapshot the exact highlighted text, Accessibility element, and range when RayPlacement opens; they never use clipboard contents as the source. The launcher reports capture, model, completion, and error stages. Press **Return** or **Replace Selection** to replace the original highlight. RayPlacement first validates that the original text is still present and attempts a direct Accessibility replacement. If the editor allows reading but refuses direct replacement, RayPlacement restores the verified exact range and uses a normal paste event. If the source changed during review, it stops instead of modifying the wrong text.

**Paste as Plain Text** now inserts through the saved macOS Accessibility text target when the receiving app supports it, including an empty cursor position or a selected range. It falls back to a standard paste event only for editors that do not expose a writable Accessibility selection, and shows a short success confirmation either way.

[Extensions/vscode-directories](Extensions/vscode-directories) adds **Open File or Directory in VS Code**. Running it opens a blank Spotlight-backed picker; type part of a file or directory name, then choose the result to open it in Visual Studio Code. It ships without a default shortcut, and the user can record one in **Settings → Extensions**.

Extensions are deliberately process-based rather than dynamically loaded libraries: a script can be written in any language installed on the Mac, reloaded without rebuilding, and isolated from the launcher's process. Extension scripts still run with your macOS user account's permissions, so only install code you wrote or reviewed.

## Build

The project requires an Apple-silicon Mac on macOS 13 or later and Swift 6 (Xcode 16 Command Line Tools or newer). Git LFS is recommended when cloning; without it, the installer downloads and verifies the pinned Qwen model and runtime. Normal app use does not need Node, Python, Ollama, or network access.

```sh
make test
make package
make verify
```

For a release candidate, run the bundled inference quality checks after packaging:

```sh
RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 RAYPLACEMENT_VERIFY_MODEL_QUALITY=1 ./scripts/verify_app.sh build/RayPlacement.app
```

The repository contains the bundled provider assets. To reproduce all historical provider assets from pinned upstream releases, run `./scripts/fetch_vendor_assets.sh`. The shipping app packages only Qwen and its pinned llama.cpp runtime; `./scripts/assemble_qwen_model.sh` verifies local assets and repairs missing ones from their official releases. Qwen adds about 1.7 GB to the app because the model is fully local.

The packaged app is written to `build/RayPlacement.app`. Without local-signing setup it falls back to ad-hoc signing and warns that Accessibility approval may be lost after a rebuild. The double-click installer performs the stable per-Mac setup automatically after explicit consent. For a manual development setup, run `./scripts/setup_local_signing.sh` once, then package with `RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 make package`. Developer ID signing and notarization are still needed to distribute a standalone prebuilt app that does not rebuild locally.

## Updates

RayPlacement checks the repository's latest GitHub Release after startup and also provides **Check for Updates** in the menu bar and **Settings → About**. It never installs silently. When a newer semantic version is available, the app shows the release notes and asks first. A dedicated progress window then stays visible while RayPlacement downloads the small model-free update kit, verifies GitHub's SHA-256 digest, reuses the installed Qwen model, rebuilds with this Mac's stable signing identity, and verifies the result. Only then does RayPlacement close briefly for the final app swap and reopen with a success report. A failed build leaves the current app running; a failed final swap restores the previous app. The detailed helper output is retained at `~/Library/Application Support/RayPlacement/Updates/update.log` so the build never disappears into an unexplained close. After a successful install, the updater deletes its validated temporary build so it does not leave another multi-gigabyte model copy behind.

Maintainers create the update kit with `./scripts/create_update_archive.sh`. Pushing a matching version tag such as `v1.10.1` runs `.github/workflows/release-update.yml`, tests the source, and publishes the update assets. The updater remains compatible with the older five-argument helper call used by RayPlacement 1.7.x. The full Desktop installer remains the recovery path if a local model or build tool is missing.

## Project layout

- `Sources/RayPlacement` — AppKit/SwiftUI application
- `Sources/RayPlacementCore` — fuzzy matching, calculator, shortcuts, and extension schema
- `Sources/RayPlacementWriting` — provider-neutral writing review parsing and plain-text paste
- `Sources/RayPlacement/NotesStore.swift`, `InlineMarkdownEditor.swift`, and `NotesWindowController.swift` — bounded local Markdown notes and inline styling
- `Sources/RayPlacement/NoteSummaryService.swift` — bounded on-demand Qwen summary workflow
- `Sources/RayPlacement/NoteDictationService.swift` — explicit record-then-transcribe on-device dictation
- `Extensions` — bundled Writing Tools, VS Code Directories, Productivity Tools, and Document Formatter extensions
- `docs/extension-manifest.schema.json` — machine-readable extension manifest contract
- `Tests` — core behavior tests
- `Examples` — example user extension
- `scripts/package_app.sh` — release build, app-bundle assembly, icon generation, and local signing
- `scripts/setup_local_signing.sh` — one-time stable personal signing identity for persistent macOS permissions
- `scripts/create_update_archive.sh` — model-free GitHub Release update kit
- `Uninstall RayPlacement.command` — recoverable app removal with optional local-data cleanup
