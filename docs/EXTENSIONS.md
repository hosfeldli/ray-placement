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

`icon` is any SF Symbols name. `subtitle`, `keywords`, and `hotkey` are optional. Hotkeys use names such as `command`, `option`, `control`, and `shift`, followed by a supported letter, number, arrow, Space, Tab, Return, Escape, or F1–F12. `command+command` is the special double-Command gesture. Every loaded command also gets a recorder in **Settings → Extensions**, where the user can replace, clear, restore, or independently disable its shortcut. Each extension and function has its own enabled checkbox; disabling one preserves its configuration.

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
| `openFormatterWorkspace` | Opens the temporary Notes workspace for EDI, JSON, and XML formatting, validation, inspection, search, and optional local-AI proposals | `value` is ignored |
| `openEmojiPicker` | Opens the native searchable emoji selector and pastes the chosen emoji into the source app | `value` is ignored |
| `shell` | Absolute or extension-relative executable path | `arguments`, `workingDirectory` |

Arguments are passed directly to the executable—RayPlacement does not assemble a shell command. Put shell logic in a script with a shebang, then mark it executable:

```sh
chmod +x bin/my-command
```

Script output is shown inside the launcher. Output is limited to 1 MB. Nonzero exit status is shown as an error.

Set `runInBackground` to `true` on a shell command to keep the launcher out of the way while it runs. RayPlacement shows a compact bottom status capsule and records the result in Usage. Leave it off when stdout is the command's primary result.

## Native input/output workflows

Schema version 2 adds a `form` action for extensions that need a real UI without app-specific Swift code. Forms support `text`, `secure`, `multiline`, `number`, `toggle`, and `picker` fields. An execution can send an `httpRequest` or invoke a trusted executable. Use `{{fieldID}}` placeholders in URL, method, headers, body, executable path, arguments, or working directory. Values stay in memory; secure values are not persisted.

The bundled `Extensions/endpoint-tester` is a complete example and receives a dedicated Postman-style workspace. It supports GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS, editable query parameters and headers, no-auth/Bearer/Basic/API-key authorization, validated JSON/text/XML bodies, cancellation, session request history, cURL export, and separate formatted Body, Headers, and Raw response views. Secrets remain only in memory and are cleared when a history entry is restored. Only HTTP(S) endpoints are accepted, response capture is capped at 2 MB, and the user's extension timeout remains the upper bound.

## Performance contract for local AI

Every executable command receives the user's current **Settings → Performance → Extensions** choice through these environment variables:

| Variable | Meaning |
| --- | --- |
| `RAYPLACEMENT_PERFORMANCE_SCALE` | Active runtime level: `eco`, `balanced`, `high`, `turbo`, `maximum`, or `unbounded` |
| `RAYPLACEMENT_THREAD_LIMIT` | Requested maximum worker threads; Unbounded supplies every logical CPU exposed by macOS |
| `RAYPLACEMENT_TIMEOUT_SECONDS` | Hard wall-clock timeout applied by RayPlacement; `0` means the user explicitly selected no timeout |
| `OMP_NUM_THREADS`, `OMP_THREAD_LIMIT`, `MKL_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS` | Common native numerical-library thread limits |
| `TOKENIZERS_PARALLELISM` | Always `false` |

RayPlacement assigns the child process background, utility, or foreground priority for the active level; continuously drains but stores at most 1 MB of output; and terminates it at the configured deadline. With Beta Dynamic Performance enabled, the active level can be lower than the user's slider ceiling when Low Power Mode or thermal pressure calls for it, so extensions must read these variables on every invocation. AI extensions should pass `RAYPLACEMENT_THREAD_LIMIT` to every inference runtime. They should load models only when invoked, unload them on exit, avoid GPU use unless clearly disclosed, and document approximate memory use. Environment thread limits are cooperative—a third-party executable can ignore them—so only run extensions you trust.

## Trust and permissions

Extensions are local code and run with your macOS user account's access. Only install scripts you wrote or reviewed. `paste`, `pastePlainText`, selected-text reading/replacement, and window management ask for Accessibility permission. `checkWriting` sends the standard Copy command to the previously focused app so it works in browsers, Electron, Office, and custom editors; RayPlacement reads only the resulting text and immediately restores the prior clipboard when no other app changed it. Accessibility selection is the fallback. Qwen runs locally and receives the correction instructions from Settings; checked text is not sent over the network. Ordinary launcher shortcuts, URL/file opening, and executable commands do not need Accessibility access. The special double-Command gesture is observed only while its hotkey is enabled and ignores Command when used in a chord. Performance limits do not turn untrusted executable code into a security sandbox.

The included `Extensions/writing-tools` manifest adds **Paste as Plain Text** and **Check Spelling & Grammar**. `Extensions/endpoint-tester` demonstrates a native form flow. `Extensions/emoji-picker` adds the searchable emoji selector with double Command as its default gesture. `Extensions/vscode-directories` adds an interactive file-or-directory search for Visual Studio Code. `Extensions/productivity-tools` adds an offline, daylight-saving-aware **Convert Timezones** view, a confirmed **Force Quit Application** picker, and a separately confirmed **Force Quit All Applications** action that excludes RayPlacement. `Extensions/document-formatter` opens a temporary Notes workspace for EDI, JSON, and XML. The top-level `Install RayPlacement.command` installs RayPlacement and every bundled extension into your user folders.

For a precise AI-oriented build and verification contract, see [EXTENSION_AUTHORING_FOR_AI.md](EXTENSION_AUTHORING_FOR_AI.md). A JSON Schema is available at [extension-manifest.schema.json](extension-manifest.schema.json).

The included `Examples/project-tools` folder is ready to copy, or run `./scripts/install_example_extension.sh` from the project.
