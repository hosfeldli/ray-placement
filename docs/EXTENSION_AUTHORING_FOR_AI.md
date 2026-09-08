# Lima extension contract for coding agents

Use this document when an AI or automation creates, repairs, or reviews a Lima extension. The goal is a small, predictable local macOS workflow that remains keyboard-first and does not widen its authority beyond the requested task.

## Non-negotiable workflow

1. Read `docs/extension-manifest.schema.json` completely.
2. Read `docs/EXTENSIONS.md` and `docs/starter-extension/manifest.json`.
3. Treat those files as the complete public manifest contract; never assume an unlisted field or action exists.
4. Choose the smallest generic native action that satisfies the request.
5. Use a schema-v2 form only when the command needs variable input or output.
6. Add an executable only when the public native actions cannot express the deterministic behavior.
7. Preserve stable extension, command, and field IDs.
8. Validate JSON, then verify loading, search, execution, cancellation, and failure feedback in Lima.

Do not invent undocumented action types or private one-off launcher modes. If the public API must change, update the Swift models, decoder, executor, schema, manuals, a bundled example, and tests in the same change.

## Recommended shape

```text
my-extension/
├── manifest.json
├── bin/
│   └── optional-reviewed-executable
└── assets/
    └── optional-local-data
```

Use reverse-domain-style IDs. Shortcut and enablement settings are keyed by `<extension id>.<command id>`; pack settings use the manifest pack metadata.

## Decision tree

```text
Does the command have fixed input?
├─ Yes → use a generic native action
└─ No
   ├─ Can a reusable picker or form solve it? → schema-v2 form or picker action
   ├─ Can a direct executable solve it safely? → schema-v2 shell form
   └─ Does it require a large persistent surface? → propose a reviewed native host capability
```

Do not recreate the removed tab system or force an ordinary instant action into a separate workspace.

## Generic action contract

Supported action types are:

`application`, `clipboard`, `file`, `form`, `picker`, `shell`, `system`, `url`, `window`, and `workspace`.

Important operations include:

* application: `quit`, `forceQuit`, `restart`, `activate`, `hide`, `unhide`, `quitAll`, `forceQuitAll`.
* clipboard: `copy`, `paste`, `pastePlainText`.
* picker: `emoji`, `application`, `file`, `timezone`, `password`.
* system: `lock`, `sleep`, `screenSaver`, `logout`, `restart`, `shutdown`.
* window: the standard half, third, quarter, maximize, center, restore, and display operations documented in `EXTENSIONS.md`.
* workspace: only operations explicitly implemented by Lima and documented by the corresponding maintained feature.

Generic fields are `value`, `operation`, `target`, `confirmation`, `parameters`, `arguments`, `workingDirectory`, `form`, and `chain`. Use `confirmation: true` for a destructive request; the host owns the final confirmation behavior.

## Forms

Supported field types are `text`, `secure`, `multiline`, `number`, `toggle`, `picker`, `file`, `directory`, `date`, `slider`, and `keyValue`.

Use `visibleWhen` to remove irrelevant fields. Mark only truly mandatory fields as `required`. Use `secure` for secrets and never substitute secret values into visible output.

The only form execution type is direct `shell` execution:

```json
"execution": {
  "type": "shell",
  "executable": "/usr/bin/wc",
  "arguments": ["-w", "{{inputFile}}"],
  "timeoutSeconds": 20
}
```

Rules:

1. Invoke an executable directly.
2. Pass every argument as its own JSON array element.
3. Use explicit system paths because GUI apps receive a minimal `PATH`.
4. Treat every value as untrusted.
5. Never use `eval`, `zsh -c`, `bash -c`, or string-built commands.
6. Start extension scripts with an explicit shebang and fail on errors.
7. Verify exact targets before modifying or deleting data.
8. Write useful results to stdout and actionable errors to stderr.
9. Stay below the 1 MB output cap.
10. Do not create daemons, login items, persistent watchers, or hidden services.

## Bounded chains

A `chain` contains no more than eight approved native actions. It cannot contain shell, form, URL, or file actions and is not an arbitrary scripting language. Use it only when each step is independently safe and deterministic.

## Capabilities

Request the smallest manifest capability set. Native action requirements are checked when the extension loads. User extensions requesting capabilities require explicit approval, and changed manifests require re-approval.

Never use `externalExecution` unless the command truly invokes an executable outside the extension directory. Prefer a reviewed extension-relative executable when practical.

## Search, arguments, and feedback

Titles, subtitles, keywords, exact matches, prefixes, context, frequency, recency, and favorites contribute to launcher ranking. Make the title describe the user-facing result, and put synonyms in keywords.

Instant operations should complete through a toast/activity capsule. Use a full surface only for actual input, review, or output. Escape must cancel an active picker or confirmation without changing the target application or clipboard.

## Review checklist

* Manifest JSON is valid and matches the schema.
* All IDs are stable and unique.
* Every action type and operation is documented.
* Capabilities are minimal and sufficient.
* No arbitrary command interpreter is used.
* Destructive operations have an explicit confirmation path.
* Filesystem paths remain within the extension boundary unless explicitly approved.
* Secure values are not logged or persisted.
* The command works with keyboard-only navigation.
* The command produces compact success and actionable failure feedback.
