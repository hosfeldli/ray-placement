# AI Connections implementation status

Lima Access is built into normal Lima, separate from the QA-only MCP control socket. Both transports are **off by default** and must be enabled individually in Settings → AI Connections.

## Available now

- **Local MCP:** `http://127.0.0.1:43821/mcp` binds only to loopback.
- **Network MCP:** `https://<selected-private-IPv4>:43822/mcp` uses a separate TLS listener bound to one currently assigned RFC 1918 or Tailscale/CGNAT address. Enabling it never exposes the plaintext local listener to the LAN. If startup fails, the persisted network opt-in is cleared; stopping or restarting a listener invalidates responses accepted by its earlier generation.
- **TLS identity and discovery:** Lima generates a P-256 signing key in Keychain and a self-signed certificate with the selected IP in its SAN. The exact certificate persists across listener restarts, and Settings displays its SHA-256 fingerprint and lets the user copy the certificate. A network client must trust or pin that certificate **before** sending a token; do not disable certificate verification. While the network listener runs, Bonjour advertises `_lima-mcp._tcp` with only TLS, pairing, and protocol-version hints—no token or user data.
- **Per-client pairing and revocation:** Settings creates a random 256-bit bearer token for a named Read Only client, displays it once, stores it in Keychain, and records only client metadata in a user-only file. Network and local credentials are transport-scoped and cannot be exchanged. Revoking one client invalidates only that token. Lima rechecks authorization after asynchronous MCP work, before queuing the response.
- **Read Only MCP profile:** Paired clients can discover a Notes URI template, list/read bounded Notes resources, search/read Notes through bounded tools, and inspect non-sensitive Lima status and effective capabilities. They cannot run computer actions or access chats, clipboard, browser control, terminal, extensions, QA controls, or settings.
- **Bounded HTTP transport:** Both transports use one JSON-RPC request per connection, a 128 KB request ceiling, an 8 KB header ceiling, an absolute five-second request deadline, and a four-connection work limit. Lima rejects ambiguous framing, duplicate/invalid Content-Length, coalesced trailing bytes, invalid Host, and browser Origin headers. Network Host must match the selected IP and TLS port exactly. Responses are non-cacheable.

Settings provides generic MCP connection JSON; client configuration field names and certificate-trust setup vary by client. Bonjour discovery does not grant access.

## In-app AI tools

Tool Access is separate from external Lima Access. **Automatic**, **Ask for actions**, and **Full Control** route all currently eligible native tool schemas. **Custom** preserves the user's saved per-tool switches, but every enabled and policy-eligible tool is visible for the full turn without prompt-keyword matching. The model sees only schemas Lima can currently route. Live action categories, browser site grants, and required approvals still determine what can execute.

Enabled connected services with freshly declared read-only tools are discoverable through Lima's `lima_list_connected_tools` and `lima_call_connected_tool` broker for both API and CLI models. Service URLs and credentials stay in Lima rather than being attached directly to model-provider requests. Each call rechecks the captured turn's server identity, current enablement, live read-only declaration, and service response.

Subagents inherit only the parent turn's captured routed tools and read-only connected services; disabling a tool or site grant later still blocks execution. Up to three child requests can run per parent turn, and independent requests from the same model response run concurrently. Activity displays numbered children with their model, task summary, and individual running/completed/failed state. Approval-gated child actions remain in the parent's normal Lima approval UI and concurrent requests wait in a FIFO queue; cancellation rejects every outstanding request.

To let Lima AI run local builds or tests, explicitly set **Terminal and code → Ask every time** in AI Settings. The terminal tool then appears in Automatic/Ask mode without another toggle. It runs one non-shell, allowlisted developer command at a time in a validated home-directory working tree, with a default 180-second timeout, a 300-second maximum, bounded output, and approval for every run. Project code runs as the current macOS user, not in a security sandbox; review commands and project scripts before approving.

For public-web research, `search_web` uses a configured Brave Search API key and `read_web` reads bounded public pages without browser cookies. When that search provider is unavailable, `browser_search_web` can open a bounded Google results query through Browser Bridge **only** if Browser navigation is enabled and Google has a live site grant; Lima's normal navigation approval or journal setting still applies. The AI can then use `browser_read` on the granted results tab and navigate to granted links. Form submission and browser interaction retain their separate safeguards.

## Not implemented

OAuth protected-resource metadata, one-time expiring pairing-code exchange, a production stdio adapter, Workspace/Full Control **external-connection** profiles, mutable MCP tools, wider Lima resources, and a detailed connection activity log are not available. The network bearer token is persistent until revoked, not a ten-minute pairing code. External clients remain Read Only even when in-app Tool Access is Full Control.

## Verification

- `swift test` covers HTTP/MCP bounds, transport authorization rules, tool schemas, routing, and browser search URL construction.
- `LIMA_TEST_MODE=1 LIMA_ACCESS_LIVE_TESTS=1 swift test --filter 'isolatedTLSNetworkPairingScopesAndRevokesBearer|isolatedNetworkTLSIdentityCanBeLoaded|pairedLoopbackMCPRejectsRevokedBearer'` uses isolated storage and Keychain items to exercise pinned HTTPS, local/network credential separation, listener restart, certificate persistence, and revocation. The live tests serialize their shared listener and Keychain state.
