# Build a RayPlacement extension

RayPlacement extensions add searchable commands and compact native workflows without rebuilding the app. An extension is a folder containing a UTF-8 `manifest.json`; it may also contain reviewed executables and local assets.

Installed extensions live at:

```text
~/Library/Application Support/RayPlacement/Extensions/
```

Open that folder from RayPlacement, add or edit an extension, then run **Reload Extensions**. Commands appear in search immediately. Every command has its own enable switch and optional configurable shortcut in **Settings → Extensions**.

## Choose the smallest tool

| Need | Use |
| --- | --- |
| Open a URL, file, folder, or app | A schema-v1 built-in action |
| Copy or paste fixed text | `copy`, `paste`, or `pastePlainText` |
| Ask for a few inputs and return output | A schema-v2 `form` |
| Make an HTTP request | A form with `httpRequest` execution |
| Run trusted local logic | A form or command with `shell` execution |
| Build a large persistent workspace | Add a native tool to RayPlacement itself |

Prefer built-in actions and forms. They inherit keyboard navigation, validation, safe argument handling, compact feedback, and the current prismatic interface automatically.

## Five-minute extension

Create `my-tools/manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "local.example.my-tools",
  "name": "My Tools",
  "description": "Small shortcuts for my workflow",
  "commands": [
    {
      "id": "open-projects",
      "title": "Open Projects",
      "subtitle": "Show my local project folder",
      "keywords": ["code", "folder", "work"],
      "icon": "folder.fill",
      "action": {
        "type": "file",
        "value": "~/Projects"
      }
    }
  ]
}
```

IDs are persistence keys. Use reverse-domain-style extension IDs and never change a released extension or command ID unless you intend to reset its shortcut and enablement preferences. `icon` is an SF Symbols name.

## Command reference

A command requires `id`, `title`, and `action`.

| Field | Purpose |
| --- | --- |
| `subtitle` | One short outcome-oriented explanation |
| `keywords` | Alternate words users will search |
| `icon` | SF Symbols name |
| `hotkey` | Optional default such as `command+shift+p` |
| `runInBackground` | Keep the launcher free and report progress in a compact status box |

Hotkeys support `command`, `option`, `control`, and `shift`, followed by a letter, number, navigation key, or F1–F12. `command+command` is the double-Command gesture. Default hotkeys should be rare; users can record and independently enable a shortcut for each command.

### Built-in actions

| Type | Behavior | `value` |
| --- | --- | --- |
| `url` | Open a web URL | Required URL |
| `file` | Open a path | Absolute, `~`-relative, or extension-relative path |
| `application` | Open an app | Path to `.app` |
| `copy` | Copy fixed plain text | Text to copy |
| `paste` | Paste fixed text into the prior app | Text to paste |
| `pastePlainText` | Paste current clipboard without rich formatting | Empty |
| `checkWriting` | Check and replace the exact selected text locally | Empty |
| `openFocusedFileLauncher` | Choose a file/folder in Finder, then open it with an installed app | Empty |
| `convertTimezones` | Open the offline timezone converter | Empty |
| `forceQuitApplications` | Pick and confirm one app to force quit | Empty |
| `forceQuitAllApplications` | Confirm and quit foreground apps except RayPlacement | Empty |
| `openFormatterWorkspace` | Open the EDI/JSON/XML workspace | Empty |
| `openEmojiPicker` | Search the full Unicode emoji set and paste one | Empty |
| `openPasswordGenerator` | Open the password generator | Empty |
| `openExtensionDevelopment` | Open these maintained manuals | Empty |
| `shell` | Launch an executable directly | Executable path |
| `form` | Present a native input/output workflow | See below |

## Dynamic forms

Use `schemaVersion: 2` for forms. RayPlacement lays out only the fields that currently matter, validates them before execution, and displays output in the shared workspace. A tool can remain in the main window or be popped out by the user.

Available fields:

| Type | Best for | Useful options |
| --- | --- | --- |
| `text` | Short values | `placeholder`, `defaultValue` |
| `secure` | Passwords and tokens | Never persisted or logged |
| `multiline` | Bodies, scripts, documents | `placeholder` |
| `number` | Numeric input | `minimum`, `maximum` |
| `toggle` | A binary choice | `defaultValue` |
| `picker` | A fixed set of choices | `options` |
| `file`, `directory` | Native path selection | `required` |
| `date` | A date value | `defaultValue` |
| `slider` | Bounded tuning | `minimum`, `maximum` |
| `keyValue` | Headers, variables, metadata | Repeatable rows |

All fields accept `id`, `label`, `section`, `helpText`, `required`, and `visibleWhen` where applicable. Keep help text short and use it only where the expected input is not obvious.

```json
{
  "schemaVersion": 2,
  "id": "local.example.request-tools",
  "name": "Request Tools",
  "commands": [
    {
      "id": "inspect-endpoint",
      "title": "Inspect Endpoint",
      "icon": "network",
      "action": {
        "type": "form",
        "value": "",
        "form": {
          "title": "Inspect Endpoint",
          "submitLabel": "Send",
          "fields": [
            {
              "id": "url",
              "label": "URL",
              "type": "text",
              "required": true,
              "section": "Request"
            },
            {
              "id": "authType",
              "label": "Authentication",
              "type": "picker",
              "options": ["None", "Bearer"],
              "defaultValue": "None",
              "section": "Authentication"
            },
            {
              "id": "token",
              "label": "Bearer token",
              "type": "secure",
              "required": true,
              "section": "Authentication",
              "visibleWhen": { "field": "authType", "equals": "Bearer" }
            }
          ],
          "execution": {
            "type": "httpRequest",
            "method": "GET",
            "url": "{{url}}",
            "headers": {
              "Authorization": "Bearer {{token}}"
            },
            "timeoutSeconds": 30
          }
        }
      }
    }
  ]
}
```

`visibleWhen` accepts `equals` or `notEquals`. Required validation applies only while the field is visible.

## Execution and templates

A form execution is either:

- `httpRequest`: `method`, `url`, `headers`, `body`, and `timeoutSeconds`. Only HTTP(S) is accepted.
- `shell`: `executable`, `arguments`, `workingDirectory`, and `timeoutSeconds`.

Insert a form value with an exact placeholder such as `{{url}}`. Substitution happens independently inside each string. RayPlacement does not concatenate or evaluate a shell command.

For shell execution, pass every argument separately:

```json
"execution": {
  "type": "shell",
  "executable": "/usr/bin/wc",
  "arguments": ["-w", "{{file}}"],
  "timeoutSeconds": 20
}
```

Never use `eval`, `zsh -c`, or another command interpreter to process user input. Output is capped at 1 MB. Put complex logic in a reviewed extension-relative executable with an explicit shebang and executable permission.

## Feedback, performance, and privacy

Use `runInBackground: true` for work that does not require the form to stay open. RayPlacement shows a compact status indicator and leaves the launcher available. Commands receive cooperative resource settings on every run:

| Variable | Meaning |
| --- | --- |
| `RAYPLACEMENT_PERFORMANCE_SCALE` | `eco`, `balanced`, `high`, `turbo`, `maximum`, or `unbounded` |
| `RAYPLACEMENT_THREAD_LIMIT` | Requested worker ceiling |
| `RAYPLACEMENT_TIMEOUT_SECONDS` | Wall-clock limit; `0` means explicitly unbounded |
| `OMP_NUM_THREADS`, `OMP_THREAD_LIMIT`, `MKL_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS` | Common native worker limits |
| `TOKENIZERS_PARALLELISM` | `false` |

Beta Dynamic Performance may lower the active level during Low Power Mode or thermal pressure. Read these values for each run. They are performance guidance, not a security sandbox.

Rules for sensitive data:

- Use `secure` for credentials and consume them only for the current run.
- Never echo secrets, request authorization headers, selected writing, clipboard data, or dictated text.
- State network access, filesystem writes, and destructive behavior in the command subtitle and confirmation flow.
- Extensions run as the signed-in user. Install only code you trust.

## Validate and debug

Use [extension-manifest.schema.json](extension-manifest.schema.json) as the source of truth. Before sharing an extension:

1. Confirm the manifest is valid JSON and conforms to the schema.
2. Reload extensions and search by title and every important keyword.
3. Test keyboard-only navigation, validation, cancellation, success, and failure.
4. Record, disable, restore, and invoke the command shortcut.
5. Confirm secure fields never appear in saved files or logs.
6. Confirm a background command leaves the launcher responsive.
7. Test the packaged app, not only a development build.

Bundled references include `Extensions/endpoint-tester`, `Extensions/security-tools`, `Extensions/writing-tools`, `Extensions/emoji-picker`, `Extensions/vscode-directories` (Focused File Launcher), and `Examples/project-tools`.

For a strict implementation contract and a copyable prompt for coding agents, read [EXTENSION_AUTHORING_FOR_AI.md](EXTENSION_AUTHORING_FOR_AI.md).
