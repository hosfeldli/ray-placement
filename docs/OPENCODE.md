# OpenCode CLI in Lima

Install OpenCode using its [official installation instructions](https://opencode.ai/docs/), then run `opencode auth login` in Terminal. Lima discovers `opencode` in `~/.opencode/bin`, `~/.bun/bin`, `~/.local/bin`, Homebrew, or the app's inherited PATH. It does not install OpenCode or copy its credentials.

Bun installs are supported for all three CLI providers, including custom `BUN_INSTALL` and `BUN_INSTALL_GLOBAL_BIN` locations available to the app. Lima supplies the runtime PATH itself. Bun-managed JavaScript launchers run through `bun run --bun`, so Node is not required for those launchers. In **AI Settings → Conversation configuration**, leave **CLI executable** empty for automatic discovery or use **Browse…** to select the original executable in a custom location. No wrapper or shell startup script is required. A changed Codex executable takes effect when the next app-server connection is opened.

In Assistant or AI Settings, select **OpenCode CLI**. Choose **CLI default**, refresh the model list, or enter a `provider/model` ID. **Refresh Models** uses `opencode models`; **Test Connection** sends a short request using the selected model. Catalog membership is not proof of account access. Use the visible **Change…** control beside the chat model menu to choose a saved model or enter a custom ID. Existing custom selections stay available when switching models. Claude also offers its CLI aliases `sonnet`, `opus`, and `haiku`; the CLI resolves each alias.

Chat history and Lima tool results are included in each fresh CLI request. The adapter uses `opencode run --format json --agent lima`, sends the prompt over stdin, and reads assistant text events. Images are staged as temporary files and passed through `--file`; model support for images still depends on the selected model. Temporary files are deleted when the request ends. Hidden reasoning is not treated as an answer, and JSON error events fail the response even when the process exits successfully.

OpenCode's native tool permissions are denied for the adapter agent. The assistant requests Lima tools through Lima's tool envelope, discovery, routing, and approval flow. Existing OpenCode provider configuration and login remain available. These CLI permissions are not an operating-system sandbox; use a trusted local OpenCode installation and configuration. Requests use a temporary working directory, disable project configuration, sharing and automatic updates, and retain bounded output, cancellation and timeouts.

The same provider is available for Writing and Grammar through the existing tool-free inference boundary. CLI failures remain visible rather than silently switching providers.

Compatibility validation covers the official OpenCode 1.19.5 binary's agent configuration and denied tool permissions, plus isolated subprocess fixtures for model discovery and a complete Lima tool-call/continuation round trip. No personal CLI login, live provider request, real booking, or external message was used in those checks. Use Test Connection to verify your installed version, login and model.

Protocol references: [CLI](https://opencode.ai/docs/cli/), [permissions](https://opencode.ai/docs/permissions/), and [configuration](https://opencode.ai/docs/config/).

Runtime reference: [Bun installation](https://bun.sh/docs/installation) and [Bun runtime](https://bun.sh/docs/runtime). Model aliases: [Claude model configuration](https://code.claude.com/docs/en/model-config).
