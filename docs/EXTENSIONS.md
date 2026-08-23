# RayPlacement extensions

Extensions add commands without recompiling the app. They are folders inside:

`~/Library/Application Support/RayPlacement/Extensions/`

Each folder contains a `manifest.json`. A command can open a URL, file, or app; copy or paste text; or run a local executable. Choose **Reload Extensions** in RayPlacement after making changes.

## Minimal manifest

```json
{
  "schemaVersion": 1,
  "id": "local.my-tools",
  "name": "My Tools",
  "commands": [
    {
      "id": "open-projects",
      "title": "Open Projects",
      "keywords": ["code", "folder"],
      "icon": "folder.fill",
      "hotkey": "option+shift+p",
      "action": {
        "type": "file",
        "value": "~/Projects"
      }
    }
  ]
}
```

`icon` is any SF Symbols name. `subtitle`, `keywords`, and `hotkey` are optional. Hotkeys use names such as `command`, `option`, `control`, and `shift`, followed by a supported letter, number, arrow, Space, Tab, Return, Escape, or F1–F12. Every loaded command also gets a recorder in **Settings → Extensions**, where the user can replace, clear, or restore its manifest shortcut.

## Action types

| Type | `value` | Optional fields |
| --- | --- | --- |
| `url` | Full URL to open | — |
| `file` | Absolute, `~`-relative, or extension-relative path | — |
| `application` | Path to a `.app` | — |
| `copy` | Text copied to the clipboard | — |
| `paste` | Literal text pasted into the previously focused app | — |
| `pastePlainText` | Current clipboard text with rich formatting removed, then pasted | `value` is ignored |
| `checkWriting` | Selected text corrected directly by the bundled local Qwen model using the user's Writing instructions | `value` is ignored |
| `openInVSCode` | Enters an interactive Spotlight picker, then opens the chosen file or directory in Visual Studio Code | `value` is ignored |
| `convertTimezones` | Opens the offline, two-column timezone converter | `value` is ignored |
| `forceQuitApplications` | Opens a searchable running-app picker and requires confirmation before force quitting | `value` is ignored |
| `forceQuitAllApplications` | Confirms, then force quits every foreground app except RayPlacement | `value` is ignored |
| `shell` | Absolute or extension-relative executable path | `arguments`, `workingDirectory` |

Arguments are passed directly to the executable—RayPlacement does not assemble a shell command. Put shell logic in a script with a shebang, then mark it executable:

```sh
chmod +x bin/my-command
```

Script output is shown inside the launcher. Output is limited to 1 MB. Nonzero exit status is shown as an error.

## Performance contract for local AI

Every executable command receives the user's current **Settings → Performance → Extensions** choice through these environment variables:

| Variable | Meaning |
| --- | --- |
| `RAYPLACEMENT_PERFORMANCE_SCALE` | Active runtime level: `eco`, `balanced`, `high`, `turbo`, or `maximum` |
| `RAYPLACEMENT_THREAD_LIMIT` | Requested maximum worker threads, from `1` through the available CPU count (capped at `12`) |
| `RAYPLACEMENT_TIMEOUT_SECONDS` | Hard wall-clock timeout applied by RayPlacement |
| `OMP_NUM_THREADS`, `OMP_THREAD_LIMIT`, `MKL_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS` | Common native numerical-library thread limits |
| `TOKENIZERS_PARALLELISM` | Always `false` |

RayPlacement assigns the child process background, utility, or foreground priority for the active level; continuously drains but stores at most 1 MB of output; and terminates it at the configured deadline. With Beta Dynamic Performance enabled, the active level can be lower than the user's slider ceiling when Low Power Mode or thermal pressure calls for it, so extensions must read these variables on every invocation. AI extensions should pass `RAYPLACEMENT_THREAD_LIMIT` to every inference runtime. They should load models only when invoked, unload them on exit, avoid GPU use unless clearly disclosed, and document approximate memory use. Environment thread limits are cooperative—a third-party executable can ignore them—so only run extensions you trust.

## Trust and permissions

Extensions are local code and run with your macOS user account's access. Only install scripts you wrote or reviewed. `paste`, `pastePlainText`, selected-text reading/replacement, and window management ask for Accessibility permission. `checkWriting` reads only the current selection from the previously focused app and never uses the clipboard as its source. Qwen runs locally and receives the correction instructions from Settings; checked text is not sent over the network. Ordinary launcher shortcuts, URL/file opening, and executable commands do not need Accessibility access. Performance limits do not turn untrusted executable code into a security sandbox.

The included `Extensions/writing-tools` manifest adds **Paste as Plain Text** and **Check Spelling & Grammar**. `Extensions/vscode-directories` adds an interactive file-or-directory search for Visual Studio Code. `Extensions/productivity-tools` adds an offline, daylight-saving-aware **Convert Timezones** view, a confirmed **Force Quit Application** picker, and a separately confirmed **Force Quit All Applications** action that excludes RayPlacement. The top-level `Install RayPlacement.command` installs RayPlacement and every bundled extension into your user folders.

For a precise AI-oriented build and verification contract, see [EXTENSION_AUTHORING_FOR_AI.md](EXTENSION_AUTHORING_FOR_AI.md). A JSON Schema is available at [extension-manifest.schema.json](extension-manifest.schema.json).

The included `Examples/project-tools` folder is ready to copy, or run `./scripts/install_example_extension.sh` from the project.
