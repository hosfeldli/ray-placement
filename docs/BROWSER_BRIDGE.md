# Lima Browser Bridge (Zen / Firefox)

## What is implemented

Lima hosts a user-only Unix socket. A bundled native-messaging executable relays
bounded, versioned frames between that socket and the browser companion.
No HTTP listener, arbitrary JavaScript evaluation, automatic page capture, or
private-window access is provided.

Settings → Browser Bridge contains:
- Explicit bridge enable/disable, native helper install/repair/removal.
- Connection test, browser-session selection, and granted-site inspection.
- Granted tabs, visible-text preview, and deterministic Salesforce case lookup.
- Background-tab preference and open/focus/close/navigate operations.
  Every mutation requires **Allow once** in the companion popup.

AI exposes only read tools: `browser_tabs`, `browser_current`, `browser_read`,
and `salesforce_resolve_case`. They are **off by default** and must be enabled in
the existing AI Tools controls. Browser text is untrusted data, not instructions.
AI context is sent to the selected conversation provider; revoking a site does
not erase text already included in a conversation.

## Development setup

1. Build Lima and the helper with `swift build`.
2. In Lima Settings → Browser Bridge, enable the bridge and choose
   **Install Native Helper**.
3. In the target browser's `about:debugging` → This Firefox (or equivalent),
   load `BrowserBridge/manifest.json` as a temporary extension.
4. Open a normal HTTPS page, open the companion popup, and grant that exact site.
5. Use **Test Connection & Refresh Sites** in Lima.
6. Enable browser read tools in AI if needed. Browser actions are also available
   in Settings; pending mutations display a badge and require popup consent.

Temporary loading lasts only for the browser session. Never disable extension
signature checks to make development installation permanent.

Helper manifests are per-user under:
- `~/Library/Application Support/Mozilla/NativeMessagingHosts/`
- `~/Library/Application Support/Zen/NativeMessagingHosts/`

The allowlist contains only `lima-browser-bridge@liamhosfeld.com`.
The native-host name is `com.lima.browser_bridge`. If Lima is moved, repair the
helper registration from the app at its new location. Settings removal only
removes Lima-owned manifests; it does not remove unrelated native hosts.

## Release / permanent installation

`make bridge-package` creates a deterministic **unsigned** XPI for development
or submission to Mozilla. It is not a permanent-install artifact.

Obtain a Mozilla-signed XPI for the fixed extension ID through the project's
Mozilla distribution process. Supply it at package time:

```sh
LIMA_BROWSER_BRIDGE_SIGNED_XPI=/absolute/path/to/signed.xpi make package
```

Packaging checks source equality and signature metadata, signs the native helper
with the same identity as Lima, and verifies the helper's signature. Only the
browser can establish Mozilla signature trust. Install the signed XPI using the
browser Add-ons manager's **Install Add-on From File** action. Settings reveals
the bundled XPI when one is supplied.

The companion currently uses Firefox WebExtension manifest v2. This is separate
from **Lima extension manifest v3**, which remains unchanged for Lima commands,
tools, skills, and agents. A signed artifact and successful installation in the
target Zen/Firefox versions remain required release checks.

## Privacy and lifecycle

- HTTPS origins only; no credential-bearing URLs, nondefault ports, wildcard
  site grants from the popup, or `<all_urls>`.
- Optional broad HTTPS permission declaration only enables individual runtime
  grants; it does not grant every HTTPS site at install time.
- Main-frame bounded visible text, filtered links, and filtered selections.
  Inputs, editable descendants, hidden content, and private-marked DOM are
  excluded. Visible pages may still contain sensitive information: grant carefully.
- Site revocation cancels pending requests/approvals, including remove-and-regrant.
- Tab mutations recheck grants and expected source URLs before dispatch.
  Cancellation cannot undo a browser operation already dispatched.
- Reconnect generations are isolated; late replies never reach a new session.
- One message is delivered at a time per socket; frame, connection, request,
  timeout, text, and link limits bound work.
- Activity uses the existing TaskRegistry and contains metadata, not page text.
  Escape or leaving Settings does not cancel work. Use explicit Cancel/Stop.
- Unix directory/socket permissions protect against other users. This is not
  a security boundary against malicious software running as the same macOS user;
  an extension ID in a handshake is an identity check, not cryptographic proof.

## Automated checks

`swift test`: protocol/framing, installation/repair, symlink and foreign-file
protection, Unix transport, real service correlation/cancellation/shutdown,
single-listener ownership, and existing app regressions.

`make bridge-test`: companion policies, consent, bounded reads, privacy filtering,
revocation/cancellation/navigation/reconnect races, and the actual debug native
helper's split-frame duplex stdio/socket relay.

`make bridge-package`: reproducible unsigned package plus source verification.

## Manual release gate (not replaced by mocks)

- Install the signed XPI in both target Zen and Firefox builds; verify discovery.
- Confirm denied sites/private windows cannot be read.
- Read a granted page, revoke during an active operation, verify no result.
- Approve/deny/expire each tab action; verify background opens do not steal focus.
- Verify exact Salesforce Case links without guessing IDs or navigating on lookup.
- Restart browser/Lima, move the app and repair, remove/reinstall helper.
- Verify Activity Shelf Stop and Escape navigation while an approval is pending.
- Test with multiple browser profiles/sessions and explicitly choose the session.

No signed artifact or live-browser installation is implied by automated test success.
