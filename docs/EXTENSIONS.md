# Lima Extensions

Extensions are packages containing a `manifest.json` and optional local scripts. They add commands to Search and can contribute supported AI tools, skills and agents. New packages use **schema v3**; existing v1 and v2 manifests continue to load.

## Start in the app

Open **Settings → Extensions & Commands → Extension Library**. The same library is used in Workspace.

- **My Extensions** shows every package, including broken or duplicate packages. Select one to see Overview, Commands & Shortcuts, or Diagnostics.
- **Add → Install a Folder** copies a validated package. Review its capabilities and choose **Approve & Enable** before using it.
- **Add → Link a Development Folder** keeps your source in place. Lima reloads manifest edits while it is running. A changed manifest requires a new review. Unlinking never deletes your source.
- **Build** creates a working website shortcut, script command, form with script, or read-only AI text tool. It writes the manifest, executable where needed, and a quick-start README.
- **Discover** browses the existing verified catalog. A download is not permission to execute: use My Extensions to review it.

The package switch controls its commands **and** AI contributions. Individual command switches, favorites and shortcuts remain yours; a package update or disable/enable cycle does not reset them. Diagnostics identify the affected field and give a repair step. Built-in packages are restored rather than deleted. Removed user packages are moved to the hidden `.removed` folder under the installed extension directory; command preferences remain intact.

## Start from a terminal

From the Lima source repository:

```sh
swift run lima-extension init ./my-tools --id local.example.my-tools --name "My Tools" --template form
swift run lima-extension check ./my-tools
swift run lima-extension run ./my-tools run message="Hello from Lima"
swift run lima-extension pack ./my-tools ./my-tools.zip
```

Templates: `link`, `script`, `form`, and `ai-tool`. Use `check --json` for machine-readable diagnostics. `check` never runs package code. `run` explicitly runs the chosen script/form with separate arguments; test native actions and AI tools in Lima. ZIP packaging excludes hidden files, rejects links/special files, preserves executable permissions, and refuses to overwrite an existing archive. Packages are limited to 2,000 entries and 50 MB before compression.

To avoid rebuilding the CLI on every call, run `swift build --product lima-extension`, then use `.build/debug/lima-extension`.

## Four concepts

1. **Package:** stable ID, version, commands, capabilities, and optional AI contributions.
2. **Command:** a searchable action. Use a native action first; add a script or form when needed.
3. **Capability:** declared host access that the user reviews. Scripts run as the user's macOS account; declarations are **not an OS sandbox**.
4. **AI contribution:** a tool, skill or agent configuration. A tool marked `metadataOnly` cannot execute. `hostReadOnly` tools need a supported typed host adapter, package approval, and the user's AI Tool Access choice. The `ai-tool` starter is a working text-transform adapter. Declaring a tool does not turn arbitrary extension code into an AI executor.

Installed packages live in `~/Library/Application Support/Lima/Extensions/`. Stable package, command and field IDs preserve settings across updates. Linked source folders can live elsewhere. Global command-profile IDs use `extension.<package-id>.<command-id>`; shortcut storage retains its older keys for compatibility.

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
  "schemaVersion": 3,
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
  "schemaVersion": 3,
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

See `docs/EXTENSION_AUTHORING_FOR_AI.md` for the implementation contract, `Sources/RayPlacementCore/Fixtures/extension-v3.json` for the canonical API v3 fixture, and `docs/starter-extension/manifest.json` for a copy-ready local example.

## API v3 execution model

```text
Search result
   ↓
instant native action OR inline surface
   ↓
host-managed output actions
   ↓
Search
```

### Presentation

* `inline` is the default and keeps interaction in Lima's launcher.
* `workspace` is an explicit separate workspace for sustained interaction.
* `background` runs without a persistent interactive surface.
* `runInBackground` remains accepted for v1/v2 compatibility; use `presentation: "background"` in v3.
* Surfaces use the user's global timeout. `timeoutPolicy: "never"` is reserved for persistent tools, and extensions cannot set arbitrary durations.
* `Escape` returns to Search; `canPopOut` permits an explicit workspace.

### Aliases, invocation, and context

Commands may declare aliases and structured arguments. For example, an integer argument allows `pw 16` without custom query parsing. Context compatibility is declared with `invocation.context`, such as `selectedText` or `contextShelfText`. Host-provided context is preferred to independent Accessibility queries, is supplied only for the active invocation, and is not automatically written to analytics or settings.

### Typed output

An output descriptor declares whether text or files are copyable, pasteable, Shelf-eligible, or Notes-eligible. Lima exposes shared `Copy`, `Paste`, `Add to Shelf`, and `Send to Note` actions; extensions should not duplicate those controls. Shell output is shown inline and is not automatically persisted to Context Shelf.
