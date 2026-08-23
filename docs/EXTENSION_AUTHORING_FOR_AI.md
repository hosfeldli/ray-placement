# RayPlacement extension authoring guide for AI systems

This document is the implementation contract an AI coding agent should follow when creating or changing a RayPlacement extension. Prefer the smallest extension that satisfies the request. Never change the native app when a manifest and an executable script are enough.

## Where extensions live

An installed extension is one directory under:

```text
~/Library/Application Support/RayPlacement/Extensions/
```

Use this shape:

```text
my-extension/
├── manifest.json
└── bin/
    └── optional-executable
```

The source tree keeps bundled extensions under `Extensions/`. The top-level installer copies every bundled extension directory into the user location.

## Stable identity rules

- `schemaVersion` must be `1`.
- Give the extension a globally distinctive, stable `id`, such as `local.company.project-tools`.
- Every command `id` must be unique inside that extension and must remain stable across updates.
- RayPlacement persists shortcut overrides using `<extension id>.<command id>`. Renaming either ID intentionally creates a new command and leaves the previous preference orphaned.
- Do not duplicate extension IDs or command IDs. The loader rejects them deterministically.

## Complete manifest example

```json
{
  "schemaVersion": 1,
  "id": "local.example.project-tools",
  "name": "Project Tools",
  "version": "1.0.0",
  "description": "Useful commands for one project",
  "commands": [
    {
      "id": "open-dashboard",
      "title": "Open Project Dashboard",
      "subtitle": "Project Tools",
      "keywords": ["project", "dashboard", "browser"],
      "icon": "rectangle.grid.2x2.fill",
      "hotkey": "option+shift+d",
      "action": {
        "type": "url",
        "value": "https://example.com/dashboard"
      }
    },
    {
      "id": "run-status",
      "title": "Project Status",
      "subtitle": "Project Tools",
      "keywords": ["project", "status"],
      "icon": "terminal.fill",
      "action": {
        "type": "shell",
        "value": "bin/project-status",
        "arguments": ["--concise"],
        "workingDirectory": "~/Projects/example"
      }
    }
  ]
}
```

Validate manifests against [extension-manifest.schema.json](extension-manifest.schema.json). JSON must be UTF-8 and contain no comments or trailing commas.

## Command fields

Required fields are `id`, `title`, and `action`. Optional fields are:

- `subtitle`: short source or context shown below the title.
- `keywords`: search terms that do not repeat the title.
- `icon`: an SF Symbols name available on macOS 13 or later.
- `hotkey`: a default global shortcut. Users can replace, clear, or restore it in **Settings → Extensions**.

Hotkeys contain one or more modifiers (`command`, `option`, `control`, `shift`) plus one supported key, joined by `+`. Example: `control+option+p`. Defaults should be rare to avoid collisions. Prefer leaving `hotkey` out and letting the user choose one in Settings.

## Action contract

| Type | Behavior | `value` |
| --- | --- | --- |
| `url` | Opens a URL | Full URL |
| `file` | Opens a file or folder | Absolute, `~`-relative, or extension-relative path |
| `application` | Opens an app bundle | Path to `.app` |
| `copy` | Copies literal text | Text |
| `paste` | Copies literal text and sends Paste | Text |
| `pastePlainText` | Rewrites clipboard text as plain text and pastes | Empty string |
| `checkWriting` | Corrects selected text with bundled local Qwen and the user's persistent Writing instructions | Empty string |
| `openInVSCode` | Enters RayPlacement's Spotlight picker and opens the chosen file or directory in Visual Studio Code | Empty string |
| `shell` | Runs an executable directly | Absolute or extension-relative executable path |

For `shell`, `arguments` is an array passed directly to the process. RayPlacement never builds a shell command and never expands variables inside an argument. Put conditional logic and safe path expansion in the executable itself. `workingDirectory` is optional.

## Script requirements

1. Start with an explicit shebang such as `#!/bin/zsh`.
2. Use `set -euo pipefail`.
3. Mark the file executable (`chmod 755 bin/name`).
4. Treat every argument as untrusted input and quote it.
5. Never construct `eval`, `zsh -c`, or another command string from user text.
6. Use absolute paths for system tools because a GUI app has a minimal `PATH`.
7. Write useful results to stdout. Write actionable failures to stderr and exit nonzero.
8. Keep output below 1 MB. Do not wait for interactive terminal input.
9. Do not read secrets or send data over the network unless the user explicitly requested and approved that behavior.
10. Verify a file or directory exists before opening, modifying, or deleting it. Avoid destructive actions by default.

## Required AI performance behavior

An extension that starts an AI model or another expensive worker must obey RayPlacement's resource contract:

1. Read `RAYPLACEMENT_THREAD_LIMIT` and configure every model/runtime thread pool to that number or lower.
2. Honor `OMP_NUM_THREADS`, `OMP_THREAD_LIMIT`, `MKL_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS`, and `TOKENIZERS_PARALLELISM` rather than overwriting them.
3. Use `RAYPLACEMENT_PERFORMANCE_SCALE` (`eco`, `balanced`, `high`, `turbo`, or `maximum`) only to choose documented quality-versus-speed behavior; never silently download a larger model. Beta Dynamic may select a lower active value than the slider ceiling, so read it fresh for every run.
4. Finish before `RAYPLACEMENT_TIMEOUT_SECONDS`. RayPlacement will terminate the process at that deadline, so keep partial writes atomic.
5. Load the model only after command invocation and release it by exiting. Do not leave daemons, launch agents, background watchers, or live dictation sessions running.
6. Avoid GPU use by default. If GPU acceleration is genuinely necessary, state that in the manifest documentation and provide a CPU mode.
7. Bound input, output, model context, and temporary files. RayPlacement stores only the first 1 MB of process output, but the extension remains responsible for its own memory and disk usage.
8. Document approximate model download size, peak memory, network behavior, data destination, and whether the thread variables are fully enforced by the runtime.

A conservative shell extension can start with:

```zsh
thread_limit="${RAYPLACEMENT_THREAD_LIMIT:-1}"
timeout_seconds="${RAYPLACEMENT_TIMEOUT_SECONDS:-60}"
```

Validate both values before passing them as separate arguments to a runtime. Do not interpolate them into an evaluated command string.

Extensions run with the user's normal authority. Paste actions and selected-text capture can ask for macOS Accessibility permission. A `checkWriting` action must use the selected text provided by Accessibility and must not silently substitute clipboard contents. Ordinary global shortcuts, file opening, and script execution do not require Accessibility permission.

## AI implementation checklist

Before presenting an extension as complete, an AI agent should:

1. Inspect the current manifest schema and an existing bundled extension.
2. Choose stable IDs and avoid default hotkeys unless requested.
3. Prefer a manifest-only action; add a script only when necessary.
4. Parse the manifest with `JSONDecoder` or run the package tests.
5. Test the executable's success path and at least one safe failure path.
6. Run `swift test`, package the app, and use the installer when changing a bundled extension.
7. Open RayPlacement, reload extensions, and confirm every new command is visible by title.
8. Open **Settings → Extensions** and confirm the command has a shortcut recorder.
9. Run the command from the launcher and, if practical, from a configured hotkey.
10. For AI extensions, test Eco and Maximum, then enable Beta Dynamic and confirm the launched process honors the active thread count and exits at its deadline.
11. Document permissions, performance behavior, approximate memory, local storage, network use, external tools, and failure behavior.

## Reference extensions

- `Extensions/writing-tools` demonstrates native actions (`pastePlainText` and `checkWriting`).
- `Extensions/vscode-directories` demonstrates the native interactive `openInVSCode` action.
- `Examples/project-tools` demonstrates URL, file, and shell commands.

When future functionality requires parameters, interactive forms, streaming, or richer command results, evolve the schema version deliberately instead of hiding a new protocol inside existing fields.
