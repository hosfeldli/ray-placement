# Build a Lima extension

Lima extensions add searchable commands and compact local macOS workflows without rebuilding the app. An extension is a folder containing a UTF-8 `manifest.json`; it may also contain reviewed executables and local assets.

Installed extensions live at:

```text
~/Library/Application Support/Lima/Extensions/
```

Open that folder from Lima, add or edit an extension, then run **Reload Extensions**. Commands appear in global search immediately. Every command has its own enable switch and optional configurable shortcut in **Settings → Extensions**.

## Design principles

* Prefer a generic native capability over a shell script.
* Keep commands small, local, keyboard-first, and outcome-oriented.
* Request only the manifest capabilities the command needs.
* Use forms only when a command needs interactive input.
* Use a bounded native action chain instead of an arbitrary workflow language.
* Do not create daemons, login items, hidden watchers, or background services.

## Manifest metadata

A manifest may identify a built-in pack:

```json
{
  "schemaVersion": 2,
  "id": "com.example.window-tools",
  "name": "Window Tools",
  "version": "1.0.0",
  "pack": "Window Management",
  "category": "Window Management",
  "bundled": false,
  "provenance": "userInstalled",
  "commands": []
}
```

Stable extension and command IDs are persistence keys. Do not change released IDs unless resetting shortcut and enablement preferences is intentional. Bundled manifests use `bundled: true`, `provenance: "bundled"`, and `trust: "bundled"`; user extensions should not impersonate that provenance.

## Minimal extension

Create `my-tools/manifest.json`:

```json
{
  "schemaVersion": 2,
  "id": "local.example.my-tools",
  "name": "My Tools",
  "description": "Small shortcuts for a local workflow",
  "capabilities": ["filesystem"],
  "commands": [
    {
      "id": "open-projects",
      "title": "Open Projects",
      "subtitle": "Show the local project folder",
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

## Commands and public actions

A command requires `id`, `title`, and `action`. Optional fields are `subtitle`, `keywords`, `icon`, `hotkey`, and `runInBackground`.

Hotkeys support `command`, `option`, `control`, and `shift`, followed by a letter, number, navigation key, or F1–F12. `command+command` is the double-Command gesture. Default hotkeys should be rare; users can record and independently enable each shortcut.

| Type | Common operations | Purpose |
| --- | --- | --- |
| `application` | `quit`, `forceQuit`, `restart`, `activate`, `hide`, `unhide`, `quitAll`, `forceQuitAll` | Manage a frontmost app, a selected app, or a safe set of user applications. |
| `clipboard` | `copy`, `paste`, `pastePlainText` | Copy or paste local text using Lima’s focus and clipboard services. |
| `file` | — | Open a file or folder relative to the extension or through a user path. |
| `picker` | `emoji`, `application`, `file`, `timezone`, `password` | Request a reusable native picker or utility surface. |
| `system` | `lock`, `sleep`, `screenSaver`, `logout`, `restart`, `shutdown` | Request a native macOS system operation. Destructive operations use shared confirmation. |
| `window` | `leftHalf`, `rightHalf`, `topHalf`, `bottomHalf`, `maximize`, `center`, `leftThird`, `centerThird`, `rightThird`, `leftTwoThirds`, `rightTwoThirds`, `topLeftQuarter`, `topRightQuarter`, `bottomLeftQuarter`, `bottomRightQuarter`, `restorePrevious`, `nextDisplay`, `previousDisplay`, `mainDisplay` | Manage the focused window through the host Accessibility service. |
| `workspace` | Feature-defined reviewed operations | Open a maintained Lima surface, such as writing review or extension repair. |
| `url` | — | Open a URL with the system workspace. This is not a request executor. |
| `shell` | — | Run one approved executable directly, without a command interpreter. |
| `form` | Shell execution only | Collect native fields and invoke one approved executable with separate arguments. |

Generic action fields include `operation`, `target`, `confirmation`, `parameters`, `arguments`, `workingDirectory`, `form`, and `chain`. Use an empty `value` when an operation does not need a value.

Examples:

```json
{
  "type": "window",
  "operation": "leftHalf"
}
```

```json
{
  "type": "application",
  "operation": "forceQuit",
  "target": "picker",
  "confirmation": true
}
```

```json
{
  "type": "system",
  "operation": "restart",
  "confirmation": true
}
```

Bundled commands and user commands use the same public action dispatch path. Lima owns the native implementation of permissions, pickers, focus restoration, confirmations, and feedback.

## Forms and direct executables

Forms support these field types:

`text`, `secure`, `multiline`, `number`, `toggle`, `picker`, `file`, `directory`, `date`, `slider`, and `keyValue`.

All fields accept `id`, `label`, `section`, `helpText`, `required`, and `visibleWhen` where applicable. Required validation applies only while a field is visible.

The only form execution type is `shell`:

```json
{
  "type": "form",
  "value": "",
  "form": {
    "title": "Count Lines",
    "submitLabel": "Count",
    "fields": [
      {
        "id": "inputFile",
        "label": "File",
        "type": "file",
        "required": true,
        "section": "Input"
      }
    ],
    "execution": {
      "type": "shell",
      "executable": "/usr/bin/wc",
      "arguments": ["-l", "{{inputFile}}"],
      "timeoutSeconds": 20
    }
  }
}
```

Pass every argument separately. Never use `eval`, `zsh -c`, `bash -c`, or a string-built command. Lima resolves executable and working-directory paths inside the extension boundary and caps captured output at 1 MB.

## Native pickers and command arguments

The host provides reusable application, display, file, and generic list/grid picker surfaces. An application result can include the name, bundle identifier, bundle URL, PID, and icon. Commands may receive launcher arguments through `parameters` or `arguments` where the host surface supports them:

* `emoji fire` starts the emoji picker with `fire` as its query.
* `restart chrome` can preselect a matching running application.
* `move left` can resolve to the `leftHalf` window command.

A picker must return focus to the prior application when the operation requires insertion. Escape cancels without changing the target application or clipboard.

## Bounded action chains

Use `chain` for a short sequence of approved native actions. Chains are limited to eight actions and cannot contain shell, form, URL, or file actions. They are not a scripting language.

```json
{
  "type": "workspace",
  "operation": "restart-development-tools",
  "chain": [
    {"type": "application", "operation": "quit", "target": "picker"},
    {"type": "window", "operation": "nextDisplay"}
  ]
}
```

## Capabilities and safety

Declare the smallest set of capabilities required by the manifest:

* `filesystem` for local file access.
* `clipboard` for clipboard operations.
* `accessibility` for focus, insertion, and window operations.
* `processControl` for application operations and application pickers.
* `systemControl` for system operations.
* `shell` for direct executable invocation.
* `externalExecution` only when an executable is outside the extension directory.
* `selectedText` for selected-text workflows.
* `network` only for a URL-opening command that genuinely needs it.

User extensions require approval when they request capabilities. Bundled packs are shipped and verified with Lima. Extensions run with the signed-in user’s permissions; install only code you trust.

Rules for sensitive data:

* Use `secure` for credentials and consume them only for the current run.
* Never echo secrets, selected writing, clipboard data, or dictated text.
* State filesystem writes and destructive behavior in the command subtitle and confirmation flow.
* Use shared native confirmation for force quit, logout, restart, shutdown, and other destructive operations.

## Feedback and validation

Instant actions should return a compact toast or activity capsule and let Lima disappear. Full workspaces are reserved for input, review, or output that requires sustained interaction.

Before sharing an extension:

1. Validate the manifest JSON against `docs/extension-manifest.schema.json`.
2. Reload extensions and search by title and important keywords.
3. Test keyboard-only navigation, validation, cancellation, success, and failure feedback.
4. Record, disable, restore, and invoke the command shortcut.
5. Confirm secure fields never appear in saved files or logs.
6. Confirm a background command leaves the launcher responsive.
7. Test the installed extension in Lima, not only its executable in Terminal.

See `docs/EXTENSION_AUTHORING_FOR_AI.md` for the implementation contract and `docs/starter-extension/manifest.json` for a copy-ready local example.
