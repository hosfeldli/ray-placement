# RayPlacement

RayPlacement is a focused, native, keyboard-first macOS launcher inspired by the standard command-launching side of Raycast. It has no analytics or account, and its optional model-powered writing checker runs entirely on this Mac.

## Use it

1. Double-click `Install RayPlacement.command` to install the app and its bundled extensions, or open `build/RayPlacement.app` directly.
2. Press **Option-Space** from any app to show or hide it.
3. Type an app, command, or calculation and press **Return**.
4. Open **RayPlacement Settings** to record a different activation shortcut, enable launch at login, or opt in to local clipboard history.

RayPlacement also lives in the menu bar. Clipboard history is off by default and, if enabled, stores text locally in `~/Library/Application Support/RayPlacement`.

If Raycast is still running with Option-Space assigned, disable or change its shortcut so both launchers do not respond together.

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
- Keyboard navigation with arrows or Control-P/Control-N, Return, Escape, Command-1 through Command-9, and Command-comma

Window changes, automatic paste, and the Lock Screen command request macOS Accessibility permission only when used. The launcher hotkey itself needs no special permission.

## Add functionality

Choose **Open Extensions Folder** in the launcher and add a folder containing `manifest.json`. The complete format is in [docs/EXTENSIONS.md](docs/EXTENSIONS.md), [docs/EXTENSION_AUTHORING_FOR_AI.md](docs/EXTENSION_AUTHORING_FOR_AI.md) gives future AI agents an exact build-and-verification workflow, and [Examples/project-tools](Examples/project-tools) is a working example.

The included [Extensions/writing-tools](Extensions/writing-tools) extension adds **Paste as Plain Text** (`Control-Option-V`) and **Check Spelling & Grammar** (`Control-Option-G`). Choose the engine in **Settings → Writing**:

- **Harper** is the default: fast, rule-based, explainable, and bundled as an offline arm64 executable.
- **T5-small CoEdit INT8** is a bundled local ONNX rewrite model for short English passages. The published model is an INT8 conversion of `Unbabel/gec-t5_small`; it is not an official checkpoint from the CoEdIT paper authors.
- **Qwen3 1.7B Q8 (Deep)** is the heavier option for difficult spelling, grammar, word-choice, and punctuation errors. RayPlacement bundles the official Apache-2.0 Qwen model and a pinned llama.cpp runtime, so it does not require Ollama.

All three providers run locally and do not send checked text over the network. Writing checks read only the text selected in the previously focused app through macOS Accessibility. They never fall back to clipboard contents. When a corrected version is ready, choose **Replace Selected Text** in the review.

[Extensions/vscode-directories](Extensions/vscode-directories) adds **Open File or Directory in VS Code**. Running it opens a blank Spotlight-backed picker; type part of a file or directory name, then choose the result to open it in Visual Studio Code. It ships without a default shortcut, and the user can record one in **Settings → Extensions**.

Extensions are deliberately process-based rather than dynamically loaded libraries: a script can be written in any language installed on the Mac, reloaded without rebuilding, and isolated from the launcher's process. Extension scripts still run with your macOS user account's permissions, so only install code you wrote or reviewed.

## Build

The project requires macOS 13 or later, Swift 6 (Xcode 16 Command Line Tools or newer), and Git LFS when cloning the bundled model assets. Node/npm is only needed to reproduce the pinned T5 runtime; normal app use does not need Node, Python, Ollama, or network access.

```sh
make test
make package
make verify
```

The repository contains the bundled provider assets. To reproduce them from pinned upstream releases, run `./scripts/fetch_vendor_assets.sh`; it verifies the Harper archive, both model sets, Node, and llama.cpp before packaging the macOS arm64 inference files the app uses. The Qwen option adds about 1.7 GB to the app because the model is fully local.

The packaged app is written to `build/RayPlacement.app`, targets Apple silicon, and is ad-hoc signed for local use. Moving it to `/Applications` gives launch-at-login the most stable app path. Rebuilding changes the ad-hoc signature, so macOS may ask for Accessibility approval again. Developer ID signing and notarization are needed to distribute it reliably to other Macs.

## Project layout

- `Sources/RayPlacement` — AppKit/SwiftUI application
- `Sources/RayPlacementCore` — fuzzy matching, calculator, shortcuts, and extension schema
- `Sources/RayPlacementWriting` — provider-neutral writing review parsing and plain-text paste
- `Extensions` — bundled Writing Tools and VS Code Directories extensions
- `docs/extension-manifest.schema.json` — machine-readable extension manifest contract
- `Tests` — core behavior tests
- `Examples` — example user extension
- `scripts/package_app.sh` — release build, app-bundle assembly, icon generation, and local signing
