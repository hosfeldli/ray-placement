# Testing Lima UI

## AI UI Lab

The debug UI Lab renders the **production AI workspace** with in-memory conversations, inert MCP/native-tool stores, and `FixtureAITransport`. It does not access Keychain or make network requests.

```sh
make visual-lab
```

Use an individual deterministic scenario when iterating on one state:

```sh
make visual VISUAL_SCENARIO=ai-markdown
```

Available AI scenarios:

- `ai-empty`
- `ai-conversation`
- `ai-markdown`
- `ai-streaming`
- `ai-approval`
- `ai-failure`
- `ai-many-chats`

The Lab is visibly marked **TEST DATA**. The fixture transport can also be injected into `AIChatViewModel` tests to exercise the real stream-to-transcript path without provider usage.

## Test credentials

Normal Lima credentials remain in their production Keychain namespaces. When `LIMA_TEST_MODE=1`, AI test data is isolated:

| Data | Production | Test mode |
| --- | --- | --- |
| OpenAI API key | `dev.liam.lima.ai` | `dev.liam.lima.ai.test` |
| MCP credentials | `dev.liam.lima.mcp` | `dev.liam.lima.mcp.test` |
| AI conversations and MCP configuration | Application Support | Per-run test data root, or `LIMA_TEST_DATA_DIRECTORY` |
| Native tool preferences | Standard defaults | Per-process test defaults suite |

For a persistent local test key, add it only to the test Keychain service:

```sh
security add-generic-password \
  -a "openai-api-key" \
  -s "dev.liam.lima.ai.test" \
  -w "$OPENAI_API_KEY" \
  -U
```

A CI or one-off local run can instead supply `LIMA_TEST_OPENAI_API_KEY`. This value takes precedence over the test Keychain value and is never persisted by Lima.

Live provider calls are disabled in test mode unless both variables are set for the current process:

```sh
LIMA_TEST_MODE=1 \
LIMA_ALLOW_LIVE_AI_TESTS=1 \
LIMA_TEST_OPENAI_API_KEY="$OPENAI_API_KEY" \
.build/debug/RayPlacement
```

To exercise Lima’s full production Responses/SSE/transcript path with test-only in-memory stores, additionally set `LIMA_RUN_LIVE_AI_TESTS=1` and run the focused integration test:

```sh
LIMA_TEST_MODE=1 \
LIMA_ALLOW_LIVE_AI_TESTS=1 \
LIMA_RUN_LIVE_AI_TESTS=1 \
LIMA_TEST_OPENAI_API_KEY="$(tr -d '\r\n' < ~/Desktop/key.key)" \
swift test --filter optInLiveResponsesPathLeavesVisibleAssistantText
```

Keep ordinary UI, snapshot, and unit tests fixture-backed. The UI Lab continues to use its fixture transport even if these variables are present.
