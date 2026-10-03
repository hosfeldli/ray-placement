# Lima Browser Bridge (Zen / Firefox)

## Install from Lima (recommended)

1. Put **Lima.app** in Applications (or its final location), launch it, and leave
   it running. Use desktop Zen or Firefox with Gecko 140+ on macOS.
2. Open **Lima Settings → Browser Bridge → Save Companion XPI…**. Save the
   bundled Mozilla-signed companion to Downloads. The copy works offline and
   preserves the signed bytes. A disabled button means this build has no signed
   companion; obtain an official release, not the unsigned development package.
3. In the intended browser/profile, open **about:addons**, choose the gear menu
   → **Install Add-on From File…**, and select the saved XPI. Review the browser's
   permission/data-consent prompts. Verify **Lima Browser Bridge 1.3.0** is enabled.
   Repeat separately for other browsers/profiles. Never disable signature checks.
4. In Lima, enable **Enable browser bridge**, choose **Install Native Helper…**,
   and confirm. Open the companion popup and choose **Reconnect to Lima**.
5. Choose **Test Connection & Refresh Sites** in Lima. Expect **End-to-end
   connection verified**. With multiple sessions, select the intended one first.
6. Visit a normal HTTPS page such as `https://example.com`. In the companion
   popup choose **Always allow reading on this site** and accept the site prompt.
   Refresh sites in Lima, choose **Refresh Granted Tabs**, select the page, and
   choose **Read Page**. Reading persists until revoked; private/internal pages
   are excluded.
7. Leave interactions at **Ask every time** unless needed. Open, focus,
   navigate, close, click, type, and submit requests appear in the companion's
   pending actions for explicit approval or denial. **Always allow interactions…**
   is a separate, site-named confirmation. AI click, type, and submit remain
   Experimental and always require a separate per-action approval in Lima.
   Navigation, closing, and submission may discard or change work.
8. To verify revocation, choose **Revoke all access**, refresh, and start a *new*
   read: it must be denied. **Ask every time** removes only persistent interaction
   access. Test persistence by restarting the browser and reconnecting. Changing
   policy cancels pending mutations rather than approving them.
9. Browser AI reading tools are selected by default on new installations and
   migrated once for older saved tool lists; users can disable them. AI still
   needs a routed request, an enabled Bridge, and a site grant. Navigation and
   Experimental interaction remain off until enabled separately in AI Settings
   and Tools. Browser context sent to AI goes to the selected conversation
   provider; revocation does not erase past conversations.

**Setup Guide…** in the same Settings pane provides the complete offline guide,
including updates, troubleshooting, removal, privacy, and Stop/Escape semantics.
**More → Show Companion Files** reveals packaged technical documentation.

### Updating, troubleshooting, and removing

- Updating Lima does **not** install/update the add-on in browsers. Save the newly
  bundled XPI, use **Install Add-on From File…** in each profile, review consent,
  check its version, reconnect, and retest. The unlisted companion is bundled
  with Lima, not a public AMO store listing.
- If Lima moves, choose **Repair Native Helper…** from its new location. Keep
  Lima running, enable the bridge, reconnect, and restart the browser if needed.
- Signature/incompatibility error: update the browser and obtain a fresh official
  XPI; do not disable security settings or use temporary loading as a release fix.
- Empty tabs or denied reads: use a normal HTTPS tab, grant its exact site, and
  refresh. A different origin/subdomain requires its own exact grant unless the
  browser separately approved broad HTTPS access and Lima's AI Settings →
  Experimental browser access switch is enabled.
- Waiting actions: open the companion popup or choose **Stop** and retry. If the
  tab navigated, refresh tabs before retrying. Cross-site navigation requires both
  sites; persistent interactions require both sites to be explicitly trusted.
- **Stop** cancels pending work; **Escape** navigates. Cancellation cannot undo
  an action already dispatched. Connection tests are not full live acceptance.
- Turn off the bridge to stop connections. **Remove Helper…** removes only Lima's
  native registrations. Uninstall the companion separately in **about:addons**;
  disabling the bridge does not itself erase browser grants or past AI context.

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
  Mutations default to **Ask every time**; the companion can explicitly remember
  **Always allow interactions** for each exact site.

AI browser tools are separated into read, navigation, and Experimental
interaction groups. Read schemas are selected by default but remain subject
to the enabled Bridge, a routed AI request, and site grants. Navigation tools
can open, focus, and navigate granted HTTPS tabs. Experimental
`browser_click`, `browser_type`, and `browser_submit` require explicit Lima
settings and individual user approval for every action; they exclude arbitrary
scripts and sensitive fields. Browser text is untrusted data, not instructions.
AI context is sent to the selected conversation provider; revoking a site does
not erase text already included in a conversation.

## Experimental broad HTTPS access in Lima

Exact-site grants remain the default. If the browser has separately approved
`https://*/*`, Lima ignores broad-only tabs while **AI Settings → Experimental
browser access → Allow broad HTTPS browser grants** is off. Exact-site tabs
continue to work. Enabling that switch lets Lima list/read eligible HTTPS tabs
and use navigation on broad-only sites, subject to the separate AI navigation
policy and the companion's tab-action approval. The switch does not grant or
revoke the browser permission; revoke it separately in the browser companion.
Turning the switch off prevents future broad-only results from reaching Lima,
including a page read already in flight. Private windows stay excluded.

Broad permission never enables AI click, type, or submit on its own. Those
actions still require an exact-site grant, the separate Browser AI interaction
setting, and individual Lima approval; the companion may also ask. The
signed 1.3.0 XPI is not changed by this Lima-side setting.

## Persistent site access (companion 1.3.0)

The popup separates two choices:
- **Always allow reading on this site**: Firefox remembers the exact HTTPS-origin
  grant until revoked; this was already persistent in 1.0.0. It does not enable
  tab mutations.
- **Always allow interactions…**: a second, site-named confirmation lets Lima
  open, focus, navigate and close tabs for that site without another popup.
  In 1.3.0 it also governs bounded click, type, and submit requests, but never
  enables arbitrary scripts or bypasses Lima's separate per-action AI approval.
  Cross-site navigation needs both source and destination interaction grants.

Both choices survive browser restarts. Interaction preferences use local
extension storage, not sync storage, with at most 256 exact sites. There is no
global "always allow" switch. **Ask every time** removes only interaction trust;
**Revoke all access** removes reading and clears remembered interactions.
Removing browser host access outside the popup also clears interaction trust,
including remove-and-regrant. Changes cancel pending mutations rather than
retroactively accepting queued requests; start a new action after changing mode.
Storage failures disable automatic interactions and display a generic error;
a failed save is not reported as a successful persisted change.

Private windows, expected-URL checks, grant checks, explicit Stop and connection
generation isolation still apply. Cancellation cannot undo an already-dispatched
tab action. Revoking access does not erase previously shared context.
The popup confirmation defaults keyboard focus to Cancel. Lima Settings displays
both modes after **Test Connection & Refresh Sites**; it cannot silently grant
interaction access. Existing 1.0.0 installations keep Ask every time.

The installed Mozilla-signed 1.3.0 XPI remains unchanged. It returns bounded
visible links (including the tested IANA example-domain URL) and supports
bounded navigation and limited page actions, but it does not enumerate safe
control selectors. The 1.3.1 signing attempt did not return an XPI locally;
its submission receipt requires AMO dashboard review before any retry. The
unreleased 1.3.2 source adds up to 100 uniquely selectable, labeled
main-document controls, rejects read-only or disabled action targets, and
hardens sensitive-field handling. It needs its own source-matching
Mozilla-signed XPI before Lima can bundle or live-test those changes. Do not
modify the signed 1.3.0 bytes or treat the 1.3.1 attempt as a release.
Earlier navigation acceptance does not certify live click, type, or submit
interactions.

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
the bundled XPI with **Save Companion XPI…** (defaulting to Downloads) and **Setup Guide…**. The guide and packaged README cover installation, per-site reading versus interaction permissions, AI data flow, revocation, updates, and troubleshooting. The package verifier is bundled for Lima's exporter.

The companion currently uses Firefox WebExtension manifest v2. This is separate
from **Lima extension manifest v3**, which remains unchanged for Lima commands,
tools, skills, and agents. A signed artifact and successful installation in the
target Zen/Firefox versions remain required release checks.

## AMO signing workflow (unlisted)

The companion uses Mozilla's **unlisted** channel and is bundled with Lima's
existing GitHub app distribution. This is not an AMO public listing and does not
change Lima's local application-signing trust anchor.

The manifest declares `browsingActivity` and `websiteContent` because URLs,
titles, visible text, links and selection can leave the browser for Lima.
Desktop Gecko **140+** is required for built-in data consent; the Android
declaration uses 142 to avoid implying support for an older consent flow.
The native helper is **macOS-only**; that declaration is not Android support.
Exact-site grants remain separately required. Installed Zen 1.22.3b reports
Gecko 156.0.1, which meets the declared minimum; this is not installation proof.

### Local credentials

Create an AMO developer account and API credentials through the
[Mozilla Developer Hub](https://addons.mozilla.org/en-US/developers/).
Do not paste credentials in chat or put them in shell arguments, source files,
`.env` files, or logs. Run locally in an interactive Terminal:

```sh
swift scripts/setup_browser_bridge_signing.swift
python3 scripts/browser_bridge_signing.py status
```

The Swift helper uses hidden prompts and stores the issuer and secret directly
in macOS Keychain under account `lima-browser-bridge`, services
`com.lima.browser-bridge.amo-issuer` and
`com.lima.browser-bridge.amo-secret`. It replaces only these two entries.
A macOS Keychain access prompt may need local approval. The status command only
checks entry presence; it does not establish successful AMO authentication.
`swift scripts/setup_browser_bridge_signing.swift --check` compiles the helper
without reading or changing Keychain.

### Prepare, then explicitly submit

Use a supported Node runtime (Node 22.13+ on the 22 line, or Node 24+).
Install pinned local tooling without npm lifecycle scripts:

```sh
npm install --prefix build/browser-bridge-tools --no-audit --no-fund --ignore-scripts --save-exact web-ext@10.7.0
make bridge-signing-prepare
make bridge-test
```

Preparation lints with warnings treated as errors, stages only the seven reviewed
companion files, builds an unsigned package and verifies its source contents.
It does not contact AMO. Signing is a distinct upload:

```sh
python3 scripts/browser_bridge_signing.py sign --submit
```

The helper retrieves the two Keychain values into the signing subprocess
environment, never command arguments. It disables web-ext config discovery,
discards ambient web-ext/Node/proxy overrides, fixes Mozilla's production API and
the unlisted channel, and suppresses raw network output. A per-version receipt
under `build/browser-bridge-signing/` prevents blind repeat submissions after an
interruption. Approval may outlast the local wait: check the AMO dashboard before
retrying. Do not delete a submission receipt merely to force another upload.
Download an already-approved XPI from AMO rather than submitting the same version
again, then verify it with:

```sh
python3 scripts/verify_browser_bridge_package.py /absolute/path/to/signed.xpi --require-signature
```

A successful synchronous submission writes
`build/browser-bridge-signing/<version>/lima-browser-bridge-signed.xpi`
and records its SHA-256 and source digest. Neither the receipt nor offline tests
claim cryptographic Mozilla trust or live acceptance.

### Package and release

Every release must carry a newly signed XPI when companion sources/version change.
Preserve the exact downloaded `.xpi` bytes: verify its source and signature metadata,
then supply its absolute path as `LIMA_BROWSER_BRIDGE_SIGNED_XPI` to both the
model-free and full package builds. Never overwrite an older published tag/release;
stage a new app version as a draft. Verify each built app contains the XPI matching
the approved receipt digest before verifying app signatures and release assets.

For a local package, pass the exact XPI, not a repacked ZIP:

```sh
LIMA_BROWSER_BRIDGE_SIGNED_XPI=/absolute/path/to/signed.xpi make package
```

Install that XPI in Zen through `about:addons` → gear menu →
**Install Add-on From File**, accept the browser's permission/consent prompt, and
run the manual matrix below against the packaged app. Firefox acceptance is a
separate gate if Firefox support is claimed.

Only after signing, installation and live acceptance pass, use
`docs/RELEASING.md` to prepare a **new** app version/tag and stage a GitHub draft.
Keep `LIMA_BROWSER_BRIDGE_SIGNED_XPI` set for the release build so both app
variants include the same companion. Do not overwrite an existing published
release. Public publication remains a separate reviewed step; the generic
release scripts do not by themselves certify the manual bridge/provider/device
matrix. Updating the website is outside this app-release workflow.

References:
- [Mozilla signing](https://extensionworkshop.com/documentation/develop/getting-started-with-web-ext/)
- [Firefox built-in data consent](https://extensionworkshop.com/documentation/develop/firefox-builtin-data-consent/)

## Privacy and lifecycle

- HTTPS origins only; no credential-bearing URLs, nondefault ports, wildcard
  site grants from the popup, or `<all_urls>`. A browser-approved
  `https://*/*` grant can be present, but Lima's separate AI experiment is off
  by default and does not acquire browser permission.
- Exact-site grants keep working while broad access is off. Broad-only page
  metadata and content are filtered before reaching Lima's AI tools; AI
  click/type/submit still require exact-site permission and individual approval.
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
- With a browser-approved broad HTTPS grant, verify Lima's experiment defaults
  off, exact-site tabs still work, broad-only tabs are hidden, enabling the
  experiment permits eligible reads/navigation, and disabling it blocks them
  again without revoking the browser grant. Verify broad-only click/type/submit
  stay blocked and exact-site interactions still ask in Lima.
- Read a granted page, revoke during an active operation, verify no result.
- In Ask every time mode, approve/deny/expire each tab action; verify background
  opens do not steal focus.
- Confirm persistent reading does not enable interactions. Cancel the Always
  interactions confirmation and verify no mode change.
- Opt in on a non-sensitive site and test all four tab actions without a prompt;
  restart the browser and confirm both preferences persist.
- Verify cross-site navigation still asks unless both sites have interaction
  grants; unrelated sites and private windows remain excluded.
- Downgrade to Ask every time without losing read access, then revoke reading,
  re-grant it and verify interaction access was not restored. Test in-flight
  revocation/Stop; previously dispatched tab actions cannot be undone.
- Verify exact Salesforce Case links without guessing IDs or navigating on lookup.
- Restart browser/Lima, move the app and repair, remove/reinstall helper.
- Verify Activity Shelf Stop and Escape navigation while an approval is pending.
- Test with multiple browser profiles/sessions and explicitly choose the session.

No signed artifact or live-browser installation is implied by automated test success. When source/version changes, provide a newly signed source-matching XPI to the release build; this supplies a safe replacement for the bundled companion in a future app release without rewriting its signed bytes.
