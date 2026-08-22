# RayPlacement

RayPlacement is a focused, native, keyboard-first macOS launcher inspired by the standard command-launching side of Raycast. It has no analytics or account. Its optional writing models, Markdown notes, and note dictation all stay on this Mac.

## Use it

1. Double-click `Install RayPlacement.command`. It verifies the bundled model assets, creates a stable local signing identity with your consent, builds and signs for this Mac, checks the resulting bundle, and installs the app and bundled extensions.
2. Press **Option-Space** from any app to show or hide it.
3. Type an app, command, or calculation and press **Return**.
4. Open **RayPlacement Settings** to change shortcuts, choose performance limits, check Accessibility status, enable launch at login, or opt in to local clipboard history.

RayPlacement also lives in the menu bar. Clipboard history is off by default and, if enabled, stores text locally in `~/Library/Application Support/RayPlacement`.

If Raycast is still running with Option-Space assigned, disable or change its shortcut so both launchers do not respond together.

### First setup on another Mac

RayPlacement currently targets Apple-silicon Macs running macOS 13 or later. Install Swift 6 from Xcode 16 Command Line Tools or newer and Git LFS, clone the repository, run `git lfs pull`, then double-click `Install RayPlacement.command`. The installer does not reuse or copy a signing key from another computer. It explains the local trust change, asks before making it, creates a private key that stays on that Mac, rebuilds RayPlacement locally, verifies both bundled writing models, and installs to `~/Applications/RayPlacement.app`.

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
- Per-extension global command hotkeys, configurable in **Settings → Extensions**
- JSON extensions for URLs, files, apps, copy/paste actions, and local executable scripts
- Included local Writing Tools extension with plain-text paste and three offline proofreading providers
- Included VS Code extension with an interactive Spotlight search for opening any indexed file or directory
- A separate Markdown Notes window with local autosave, search, pinned notes, and a single inline-formatted Markdown editor
- On-demand Qwen note summaries with review, copy, and insert-at-top actions
- Batch note dictation: it records only after you press Dictate, stops before transcription, requires on-device recognition, and deletes the temporary audio
- Independent Eco, Balanced, and High performance limits for writing models, dictation, and executable extensions
- Keyboard navigation with arrows or Control-P/Control-N, Return, Escape, Command-1 through Command-9, and Command-comma

Window changes, automatic paste, and the Lock Screen command request macOS Accessibility permission only when used. The launcher hotkey itself needs no special permission.

## Notes and dictation

Run **RayPlacement Notes** from the launcher, choose **Notes…** in the menu bar, or press **Shift-Command-N**. Notes open in a separate window and are saved as local Markdown data in `~/Library/Application Support/RayPlacement/notes.json`. There is no separate source/preview split: headings, emphasis, links, lists, tasks, quotes, inline code, and fenced code blocks are styled directly inside the editable Markdown document. Markdown syntax remains portable and visible in a muted style. Command-B, Command-I, and Command-K wrap the current selection, and Return continues lists and task lists. Formatting is debounced so typing stays responsive.

Choose **Summarize** in a note to run the bundled Qwen3 1.7B model on demand. Long notes are divided into bounded sections and reduced into a final Markdown summary; only one bundled model job can run at a time. The result opens for review and can be copied or inserted at the top of the original note. It uses **Settings → Performance → Writing**, stays CPU-only, sends no note content over the network, and exits when finished or cancelled.

Dictation is deliberately not live. Press **Dictate**, speak, then choose **Stop & Transcribe**. RayPlacement records a compact 16 kHz mono AAC file and asks Apple's Speech framework for an on-device-only transcription after recording has stopped. Long meetings are split into 45-second audio segments and transcribed sequentially, so a full recording is never expanded into memory at once. A failed segment is retried once and then represented by a timestamped marker instead of silently losing that part of the meeting. If the current language does not support on-device recognition, RayPlacement stops with an error instead of using a network service. Temporary recording and segment files are deleted after completion, cancellation, or failure. A 60-minute recording is approximately 15 MB at the configured 32 kbps rate.

## Performance controls

**Settings → Performance** has separate scales for Writing, Dictation, and AI-capable Extensions. All three default to **Eco**.

| Scale | Writing | Dictation | Executable extensions |
| --- | --- | --- | --- |
| Eco | 1 background CPU thread; 90-second limit; 256-token summaries | 15-minute meeting; 90 seconds per transcription segment | background priority; cooperative 1-thread limit; 60-second hard timeout |
| Balanced | 2 utility CPU threads; 120-second limit; 384-token summaries | 30-minute meeting; 120 seconds per segment | utility priority; cooperative 2-thread limit; 180-second hard timeout |
| High | 4 foreground CPU threads; 180-second limit; 512-token summaries | 60-minute meeting; 180 seconds per segment | foreground priority; cooperative 4-thread limit; 600-second hard timeout |

Qwen is CPU-only, never uses the GPU, launches only for a requested writing check or note summary, and exits when the job completes or times out. Its 1.7B-parameter model still temporarily uses about 2 GB of memory while loaded; choose Harper for the lightest grammar checking. Apple controls the internal scheduling of its on-device speech recognizer, so the dictation scale bounds meeting duration and each sequential segment rather than claiming an exact CPU-thread cap. RayPlacement enforces extension priority, output size, and wall-clock time; it also supplies common AI thread-limit environment variables, but an untrusted third-party executable can ignore those cooperative variables.

## Accessibility that survives rebuilds

**Settings → General → Accessibility** shows whether access is working, opens the correct System Settings pane, and reveals the exact running app so the correct bundle can be added. For local development, run `./scripts/setup_local_signing.sh` once before packaging. It creates a dedicated, local-only private signing key in `~/Library/Application Support/RayPlacement/Signing` and adds only its public certificate to the login keychain with a code-signing trust policy; no certificate or key is uploaded. Builds made with that identity keep the same macOS identity, so Accessibility approval survives future local rebuilds. Anyone who obtains that private key could sign another app as this local identity, so protect the account and do not share the signing folder. After installing the first stably signed build, remove any stale RayPlacement entries from Accessibility, add `~/Applications/RayPlacement.app` once, enable it, and relaunch RayPlacement.

## Add functionality

Choose **Open Extensions Folder** in the launcher and add a folder containing `manifest.json`. The complete format is in [docs/EXTENSIONS.md](docs/EXTENSIONS.md), [docs/EXTENSION_AUTHORING_FOR_AI.md](docs/EXTENSION_AUTHORING_FOR_AI.md) gives future AI agents an exact build-and-verification workflow, and [Examples/project-tools](Examples/project-tools) is a working example.

The included [Extensions/writing-tools](Extensions/writing-tools) extension adds **Paste as Plain Text** (`Control-Option-V`) and **Check Spelling & Grammar** (`Control-Option-G`). Choose the engine in **Settings → Writing**:

- **Harper** is the default: fast, rule-based, explainable, and bundled as an offline arm64 executable.
- **T5-small CoEdit INT8** is a bundled local ONNX rewrite model for short English passages. The published model is an INT8 conversion of `Unbabel/gec-t5_small`; it is not an official checkpoint from the CoEdIT paper authors.
- **Qwen3 1.7B Q8 (Deep)** is the heavier option for difficult spelling, grammar, word-choice, and punctuation errors. RayPlacement bundles the official Apache-2.0 Qwen model and a pinned llama.cpp runtime, so it does not require Ollama.

All three providers run locally and do not send checked text over the network. Writing checks read only the text selected in the previously focused app through macOS Accessibility. They never fall back to clipboard contents. When a corrected version is ready, choose **Replace Selected Text** in the review. The chosen Writing performance scale controls CPU priority, thread count, and a hard completion deadline.

[Extensions/vscode-directories](Extensions/vscode-directories) adds **Open File or Directory in VS Code**. Running it opens a blank Spotlight-backed picker; type part of a file or directory name, then choose the result to open it in Visual Studio Code. It ships without a default shortcut, and the user can record one in **Settings → Extensions**.

Extensions are deliberately process-based rather than dynamically loaded libraries: a script can be written in any language installed on the Mac, reloaded without rebuilding, and isolated from the launcher's process. Extension scripts still run with your macOS user account's permissions, so only install code you wrote or reviewed.

## Build

The project requires an Apple-silicon Mac on macOS 13 or later, Swift 6 (Xcode 16 Command Line Tools or newer), and Git LFS when cloning the bundled model assets. Node/npm is only needed to reproduce the pinned T5 runtime; normal app use does not need Node, Python, Ollama, or network access.

```sh
make test
make package
make verify
```

For a release candidate, run the bundled inference quality checks after packaging:

```sh
RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 RAYPLACEMENT_VERIFY_MODEL_QUALITY=1 ./scripts/verify_app.sh build/RayPlacement.app
```

The repository contains the bundled provider assets. To reproduce them from pinned upstream releases, run `./scripts/fetch_vendor_assets.sh`; it verifies the Harper archive, both model sets, Node, and llama.cpp before packaging the macOS arm64 inference files the app uses. The Qwen option adds about 1.7 GB to the app because the model is fully local.

The packaged app is written to `build/RayPlacement.app`. Without local-signing setup it falls back to ad-hoc signing and warns that Accessibility approval may be lost after a rebuild. The double-click installer performs the stable per-Mac setup automatically after explicit consent. For a manual development setup, run `./scripts/setup_local_signing.sh` once, then package with `RAYPLACEMENT_REQUIRE_STABLE_SIGNING=1 make package`. Developer ID signing and notarization are still needed to distribute a standalone prebuilt app that does not rebuild locally.

## Project layout

- `Sources/RayPlacement` — AppKit/SwiftUI application
- `Sources/RayPlacementCore` — fuzzy matching, calculator, shortcuts, and extension schema
- `Sources/RayPlacementWriting` — provider-neutral writing review parsing and plain-text paste
- `Sources/RayPlacement/NotesStore.swift`, `InlineMarkdownEditor.swift`, and `NotesWindowController.swift` — bounded local Markdown notes and inline styling
- `Sources/RayPlacement/NoteSummaryService.swift` — bounded on-demand Qwen summary workflow
- `Sources/RayPlacement/NoteDictationService.swift` — explicit record-then-transcribe on-device dictation
- `Extensions` — bundled Writing Tools and VS Code Directories extensions
- `docs/extension-manifest.schema.json` — machine-readable extension manifest contract
- `Tests` — core behavior tests
- `Examples` — example user extension
- `scripts/package_app.sh` — release build, app-bundle assembly, icon generation, and local signing
- `scripts/setup_local_signing.sh` — one-time stable personal signing identity for persistent macOS permissions
