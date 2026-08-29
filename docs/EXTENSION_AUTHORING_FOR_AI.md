# RayPlacement extension contract for coding agents

Use this document when an AI or automation creates, repairs, or reviews a RayPlacement extension. The goal is a small, predictable tool that feels native, remains keyboard-first, and does not widen its authority beyond the requested workflow.

## Non-negotiable workflow

1. Read `docs/extension-manifest.schema.json` completely.
2. Read `docs/EXTENSIONS.md` and the closest bundled example.
3. Inspect the current manifest models and executor before assuming a field or action exists.
4. Choose the smallest built-in action that can satisfy the request.
5. Use a schema-v2 form only when the command needs variable input or output.
6. Add an executable only when the public schema cannot express the required deterministic behavior.
7. Preserve stable extension, command, and field IDs.
8. Validate JSON, run package tests, package the app, and verify the installed UI.

Do not invent undocumented action types or fields. If the public API must change, update the Swift models, decoder, executor, JSON schema, both manuals, a bundled example, and tests in the same change.

## Files and identity

Source extensions are stored in `Extensions/`; user-installed extensions are stored in:

```text
~/Library/Application Support/RayPlacement/Extensions/
```

Recommended shape:

```text
my-extension/
├── manifest.json
├── bin/
│   └── optional-reviewed-executable
└── assets/
    └── optional-local-data
```

Use reverse-domain-style IDs:

- Extension: `local.company.workflow`
- Commands: short stable verbs such as `inspect`, `format`, or `open-project`
- Fields: semantic names such as `endpoint`, `authType`, or `inputFile`

Shortcut and enablement settings are keyed by `<extension id>.<command id>`. Changing an ID silently disconnects a user's preferences.

## Decision tree

```text
Does the command have fixed input?
├─ Yes → use a schema-v1 built-in action
└─ No
   ├─ Can native fields + httpRequest solve it? → schema-v2 form
   ├─ Can native fields + direct executable solve it? → schema-v2 form
   └─ Does it require a large persistent workspace? → propose a native app tool
```

Native tools stay in the single RayPlacement workspace by default and may be popped out by the user. Do not recreate the removed tab system or force ordinary workflows into separate windows.

## Minimal safe command

```json
{
  "schemaVersion": 1,
  "id": "local.example.project-tools",
  "name": "Project Tools",
  "description": "Fast local project actions",
  "commands": [
    {
      "id": "open-project",
      "title": "Open Project",
      "subtitle": "Open the project directory",
      "keywords": ["folder", "code", "repository"],
      "icon": "folder.fill",
      "action": {
        "type": "file",
        "value": "~/Projects/MyProject"
      }
    }
  ]
}
```

Titles name the action. Subtitles describe the outcome or risk. Keywords include likely synonyms rather than repeating the title. Use a real SF Symbols name. Add no default hotkey unless the user requested it or the command is truly time-critical.

## Form design contract

Supported field types are `text`, `secure`, `multiline`, `number`, `toggle`, `picker`, `file`, `directory`, `date`, `slider`, and `keyValue`.

Form rules:

- Put the primary input first and the submit action in the natural keyboard path.
- Use `section` for grouping, not decoration.
- Use `visibleWhen` to remove irrelevant fields.
- Put examples in `placeholder`; put durable explanation in brief `helpText`.
- Mark only truly mandatory fields `required`.
- Use `secure` for secrets. Never substitute a secret into visible output.
- Prefer fewer than eight simultaneously visible controls.
- Use exact `{{fieldID}}` substitutions only.

Conditional example:

```json
{
  "id": "token",
  "label": "Bearer token",
  "type": "secure",
  "required": true,
  "section": "Authentication",
  "visibleWhen": {
    "field": "authType",
    "equals": "Bearer"
  }
}
```

`visibleWhen` accepts `equals` or `notEquals`; required validation applies only while visible.

## Execution contract

For `httpRequest`, only HTTP(S) URLs are valid. Use explicit methods, bounded timeouts, and the smallest necessary headers. Do not log authorization headers, cookies, tokens, or substituted request bodies.

For `shell`:

1. Invoke an executable directly.
2. Pass each argument as its own JSON array element.
3. Use explicit system paths because GUI apps receive a minimal `PATH`.
4. Treat every value as untrusted.
5. Never use `eval`, `zsh -c`, `bash -c`, or string-built commands.
6. Start extension scripts with an explicit shebang and fail on errors.
7. Verify exact targets before modifying or deleting data.
8. Write useful results to stdout and actionable errors to stderr.
9. Exit nonzero on failure and stay below the 1 MB output cap.
10. Do not create daemons, login items, persistent watchers, or hidden network services.

Example:

```json
"execution": {
  "type": "shell",
  "executable": "/usr/bin/wc",
  "arguments": ["-w", "{{inputFile}}"],
  "timeoutSeconds": 20
}
```

## Complete API reference

This is the complete public manifest surface for the current app. A manifest
must have `schemaVersion`, `id`, `name`, and `commands`. Every command must
have `id`, `title`, and `action`. Unknown JSON keys are rejected by the schema;
do not add compatibility guesses or private metadata.

```text
manifest
  schemaVersion: 1 | 2
  id, name: non-empty strings
  version, description: optional strings
  commands: one or more commands

command
  id, title: non-empty strings
  subtitle: optional short outcome
  keywords: optional string array
  icon: optional SF Symbols name
  hotkey: optional shortcut string
  runInBackground: optional boolean
  action: action object

action
  type: supported action type below
  value: string (use an empty string when the action has no value)
  arguments, workingDirectory: optional for shell
  form: required for form
```

### Native action matrix

Use these exact `type` values. No other native actions exist.

| Action | Required `value` | What it does |
| --- | --- | --- |
| `url` | HTTP(S) URL | Opens the URL with macOS. |
| `file` | Path | Opens an absolute, `~`-relative, or extension-relative file/folder. |
| `application` | `.app` path | Opens that app. |
| `copy` | Plain text | Copies fixed text. |
| `paste` | Plain text | Copies then pastes into the prior app. |
| `pastePlainText` | `""` | Converts the current clipboard to plain text, then pastes it. |
| `checkWriting` | `""` | Runs the local spelling/grammar workflow on the exact selected text. |
| `openFocusedFileLauncher` | `""` | Opens Finder selection and lets the user choose the destination app. |
| `convertTimezones` | `""` | Opens the offline timezone converter. |
| `forceQuitApplications` | `""` | Opens the confirmed single-app force-quit picker. |
| `forceQuitAllApplications` | `""` | Opens the confirmed all-apps flow; RayPlacement is excluded. |
| `openFormatterWorkspace` | `""` | Opens the EDI/JSON/XML formatter workspace. |
| `openEmojiPicker` | `""` | Opens the Unicode emoji picker. |
| `openPasswordGenerator` | `""` | Opens the password generator. |
| `openExtensionDevelopment` | `""` | Opens the maintained extension manuals. |
| `shell` | Executable path | Starts one reviewed executable directly. |
| `form` | `""` | Opens a schema-v2 native form. |

`file`, `application`, and `shell` paths resolve first from the extension
directory unless they are absolute or begin with `~`. The app does not expand
environment variables in paths. Put an executable inside `bin/` and reference
it as `bin/tool` when the extension must travel as one folder.

### Hotkey grammar and enablement

The accepted normal form is modifiers followed by one key:

```text
command+shift+p
control+option+g
command+command
```

Valid modifiers are `command`, `option`, `control`, and `shift`. The final key
may be a letter, number, navigation key, or F1–F12. `command+command` is the
double-Command gesture. A default hotkey is only a proposal: the user can
record another shortcut, disable that shortcut, or disable the command in
Settings. Extension code must work without its shortcut.

## Form contract, from JSON to result

Forms are available only in `schemaVersion: 2`. They stay inside RayPlacement's
shared workspace by default, validate locally, and show a visible result. They
do not create a browser page or a web runtime.

Each field supports:

```text
id, label, type, placeholder, defaultValue, options, required,
section, helpText, minimum, maximum, visibleWhen
```

Field behavior is exact:

| Type | Value supplied to templates | Notes |
| --- | --- | --- |
| `text`, `secure`, `multiline` | User-entered string | `secure` is masked and must not be echoed. |
| `number`, `slider` | Decimal string | Add minimum/maximum when there is a meaningful bound. |
| `toggle` | `true` or `false` | Use a `defaultValue` of `true` or `false`. |
| `picker` | Selected option string | Supply a non-empty `options` list. |
| `file`, `directory` | Chosen full path | Native picker; do not parse shell-quoted input. |
| `date` | Date string | Use only where a date, not free text, is intended. |
| `keyValue` | App-provided serialized rows | Use for headers/variables; do not place secrets in visible output. |

Use `visibleWhen` only with a field that appears earlier in the same form:

```json
"visibleWhen": { "field": "mode", "equals": "Advanced" }
```

or:

```json
"visibleWhen": { "field": "mode", "notEquals": "None" }
```

Required checks apply only to a visible field. A field ID is the template name,
so `{{endpoint}}` means the field whose ID is `endpoint`; misspelled templates
remain literal text and are a manifest bug.

### Complete HTTP form example

This is a complete, valid native request inspector. It makes a single request,
never logs its token, and leaves the response visible for review.

```json
{
  "schemaVersion": 2,
  "id": "local.example.http-inspector",
  "name": "HTTP Inspector",
  "version": "1.0.0",
  "commands": [{
    "id": "fetch-json",
    "title": "Fetch JSON",
    "subtitle": "Request a JSON endpoint",
    "keywords": ["http", "api", "json"],
    "icon": "network",
    "action": {
      "type": "form",
      "value": "",
      "form": {
        "title": "Fetch JSON",
        "submitLabel": "Send",
        "fields": [
          {
            "id": "url",
            "label": "URL",
            "type": "text",
            "placeholder": "https://api.example.com/status",
            "required": true,
            "section": "Request"
          },
          {
            "id": "token",
            "label": "Bearer token",
            "type": "secure",
            "section": "Authentication"
          }
        ],
        "execution": {
          "type": "httpRequest",
          "method": "GET",
          "url": "{{url}}",
          "headers": {
            "Accept": "application/json",
            "Authorization": "Bearer {{token}}"
          },
          "timeoutSeconds": 20
        }
      }
    }
  }]
}
```

`httpRequest` accepts only HTTP or HTTPS. Its response view contains response
headers and a body capped at 1 MB; JSON is formatted when possible. A 2xx or
3xx response is marked successful. Requests are executed with the user's
network access, so make destination and side effects clear in the title or
subtitle.

### Complete local executable example

`manifest.json`:

```json
{
  "schemaVersion": 2,
  "id": "local.example.line-tools",
  "name": "Line Tools",
  "commands": [{
    "id": "count-lines",
    "title": "Count Lines",
    "subtitle": "Count lines in a selected file",
    "keywords": ["wc", "file", "lines"],
    "icon": "text.line.first.and.arrowtriangle.forward",
    "action": {
      "type": "form",
      "value": "",
      "form": {
        "submitLabel": "Count",
        "fields": [{
          "id": "inputFile",
          "label": "File",
          "type": "file",
          "required": true
        }],
        "execution": {
          "type": "shell",
          "executable": "bin/count-lines",
          "arguments": ["{{inputFile}}"],
          "timeoutSeconds": 15
        }
      }
    }
  }]
}
```

`bin/count-lines`:

```zsh
#!/bin/zsh
set -euo pipefail
[[ "$#" -eq 1 ]] || { print -u2 "Expected one file path"; exit 64; }
[[ -f "$1" ]] || { print -u2 "File not found: $1"; exit 66; }
/usr/bin/wc -l -- "$1"
```

Make the file executable before Reload Extensions. The extension runner starts
the executable directly with the exact argument array: it does not invoke a
shell, so quoting and injection tricks are neither needed nor supported.

## Development lifecycle and architecture map

An agent with only this repository can implement an extension using this map:

| Need | Read/change |
| --- | --- |
| Public JSON contract | `docs/extension-manifest.schema.json` |
| Author-facing reference | `docs/EXTENSIONS.md` |
| Codable types/template behavior | `Sources/RayPlacementCore/ExtensionManifest.swift` |
| Manifest discovery/errors | `Sources/RayPlacement/ExtensionLoader.swift` |
| Action execution, resource environment, output cap | `Sources/RayPlacement/ExtensionExecutor.swift` |
| Form rendering/validation | `Sources/RayPlacement/ExtensionFormWindowController.swift` |
| Shortcut parsing/recording | `Sources/RayPlacement/HotKeyManager.swift` and Settings |
| Reference manifests | `Extensions/` |
| Contract tests | `Tests/RayPlacementCoreTests/` |

The actual edit/reload loop is:

1. Create `Extensions/<folder>/manifest.json` and any `bin/` or `assets/` files.
2. Validate the manifest against the JSON schema.
3. In the app, run **Reload Extensions**.
4. Search command title and each keyword in the launcher.
5. Open Settings → Extensions; verify the individual enable switch and shortcut.
6. Exercise the failure path before the success path, then package and verify.

Do not touch `~/Library/Application Support/RayPlacement/Extensions/` while
developing the bundled source unless you intentionally need an installed-user
test. The installer copies the source `Extensions/` folder into that location.

## Failure behavior, logs, and safe repair

An extension must make failure actionable without hiding the cause:

| Situation | Required behavior |
| --- | --- |
| Invalid JSON/schema | Fix the manifest; Reload Extensions reports the load issue. |
| Missing executable/file | Fail before starting work and name the resolved path. |
| Invalid URL | Reject before the network request. |
| HTTP non-2xx/3xx | Show status and response; do not call it a success. |
| Timeout | Keep the timeout bounded unless the user configured unbounded performance. |
| User cancellation | Terminate the child process and report cancellation. |
| Secret-bearing request | Keep the secret masked; never include headers/body in logs or copied output. |

The runtime combines stdout and stderr, caps output at 1 MB, and uses a
minimal GUI-safe `PATH`:

```text
/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin
```

Use absolute executable paths for dependencies. Print a concise result to
stdout and an explanation to stderr. Never solve a failed extension by adding
`eval`, an interactive prompt, a hidden helper process, a login item, or a
background daemon.

## Agent delivery checklist

Before handing the extension to a user or another agent, provide these facts:

```text
Extension ID and command IDs:
Files added/changed:
Inputs and outputs:
Network/filesystem/destructive authority:
Secrets handling:
Shortcut default and settings behavior:
Performance/timeout/cancellation behavior:
Validation performed:
Known limitations:
```

This report makes the extension maintainable without a separate conversation.

## Product and privacy boundaries

- Dictation is the only bundled model-powered feature. Do not add cloud AI, model downloads, hidden AI requests, or generative text models to extensions.
- `checkWriting` is a deterministic local pipeline using bundled Python spelling rules and Harper grammar rules. Preserve exact selected-text capture, replacement, and clipboard restoration.
- The formatter is a dedicated temporary EDI/JSON/XML workspace, not a note type.
- Background commands use `runInBackground` and compact feedback; they do not take over the launcher.
- Never persist passwords, tokens, request authorization, selected writing, clipboard contents, or dictated text in usage logs.
- Describe network access, filesystem mutation, and destructive behavior before execution.

Extensions run with the user's account authority. Performance controls are cooperative, not a security boundary.

## Performance contract

Read the provided resource environment on every execution:

- `RAYPLACEMENT_PERFORMANCE_SCALE`
- `RAYPLACEMENT_THREAD_LIMIT`
- `RAYPLACEMENT_TIMEOUT_SECONDS`
- `OMP_NUM_THREADS`, `OMP_THREAD_LIMIT`, `MKL_NUM_THREADS`, `VECLIB_MAXIMUM_THREADS`
- `TOKENIZERS_PARALLELISM`

An unbounded timeout or thread level is explicit user configuration, not permission to leak processes or ignore cancellation. Stream or summarize large data, avoid repeated process startup, and release temporary resources after every run.

## Required verification

Before claiming completion:

- Manifest is valid JSON and conforms to `extension-manifest.schema.json`.
- IDs are unique and stable.
- The command appears after **Reload Extensions** and is discoverable by its keywords.
- Per-command enablement works.
- Shortcut recording, disabling, restoring, and invocation work.
- Required and conditional fields work with keyboard navigation.
- Success, failure, timeout, and cancellation have concise visible feedback.
- Secure values never appear in output, persistence, or logs.
- Executables receive arguments without shell evaluation and honor cancellation/resource settings.
- The workflow opens in the shared workspace and can be popped out where supported.
- `swift test`, packaging verification, installation, and installed-app UI verification pass.

Test malformed input, an empty required value, an unavailable dependency, and the largest realistic input—not only the happy path.

## Prompt template for another coding agent

Copy and fill this in:

```text
Create or update a RayPlacement extension named <name>.

Outcome:
<one observable user outcome>

Inputs:
<fields, types, required state, and examples>

Execution:
<built-in action, HTTP request, or direct executable>

Output:
<what the user should see or receive>

Constraints:
- Read docs/extension-manifest.schema.json and docs/EXTENSIONS.md first.
- Prefer the smallest manifest-only implementation.
- Keep IDs stable and add no default hotkey unless specified.
- Do not expose secrets or evaluate user input through a shell.
- Add or update schema/docs/tests if the public API changes.
- Run tests, package, install, and verify the command in the actual app UI.
```

## Review report template

```text
Extension: <id>
Schema: <version and validation result>
Commands: <IDs>
Permissions/data access: <explicit list>
Secrets handling: <where values exist and confirmation they are not logged>
Performance behavior: <timeout, threads, cancellation>
Verification: <tests and installed UI checks>
Known limits: <concise remaining limits>
```

Canonical examples: `Extensions/endpoint-tester`, `Extensions/security-tools`, `Extensions/writing-tools`, `Extensions/emoji-picker`, `Extensions/vscode-directories` (Focused File Launcher), and `Examples/project-tools`.
