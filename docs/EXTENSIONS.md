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
| `checkWriting` | Selected text checked with the locally selected Harper, T5-small INT8, or Qwen3 Deep provider | `value` is ignored |
| `openInVSCode` | Enters an interactive Spotlight picker, then opens the chosen file or directory in Visual Studio Code | `value` is ignored |
| `shell` | Absolute or extension-relative executable path | `arguments`, `workingDirectory` |

Arguments are passed directly to the executable—RayPlacement does not assemble a shell command. Put shell logic in a script with a shebang, then mark it executable:

```sh
chmod +x bin/my-command
```

Script output is shown inside the launcher. Output is limited to 1 MB. Nonzero exit status is shown as an error.

## Trust and permissions

Extensions are local code and run with your macOS user account's access. Only install scripts you wrote or reviewed. `paste`, `pastePlainText`, selected-text reading/replacement, and window management ask for Accessibility permission. `checkWriting` reads only the current selection from the previously focused app and never uses the clipboard as fallback. Harper, the INT8 model, and Qwen3 Deep are bundled and run locally; checked text is not sent over the network. Ordinary launcher shortcuts, URL/file opening, and executable commands do not need Accessibility access.

The included `Extensions/writing-tools` manifest adds **Paste as Plain Text** and **Check Spelling & Grammar**. `Extensions/vscode-directories` adds an interactive file-or-directory search for Visual Studio Code. The top-level `Install RayPlacement.command` installs RayPlacement and every bundled extension into your user folders.

For a precise AI-oriented build and verification contract, see [EXTENSION_AUTHORING_FOR_AI.md](EXTENSION_AUTHORING_FOR_AI.md). A JSON Schema is available at [extension-manifest.schema.json](extension-manifest.schema.json).

The included `Examples/project-tools` folder is ready to copy, or run `./scripts/install_example_extension.sh` from the project.
