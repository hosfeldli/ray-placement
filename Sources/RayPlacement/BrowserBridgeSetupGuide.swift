import SwiftUI

struct BrowserBridgeSetupGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Set up Zen / Firefox").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Self.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title).font(.headline)
                            Text(section.body).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, idealWidth: 580, maxWidth: 680, minHeight: 400, idealHeight: 600)
    }

    static let sections: [(title: String, body: String)] = [
        ("1. Put Lima in its permanent location",
         "Move Lima to Applications, launch it, and leave it running. The native helper registration points to this copy of Lima. If Lima is moved later, use Repair Native Helper from the new location. This bridge requires desktop Zen or Firefox with Gecko 140 or later on macOS; private windows are not supported."),
        ("2. Save the companion",
         "In Lima Settings → Browser Bridge, choose Save Companion XPI… and save the file to Downloads. This copies the bundled Mozilla-signed companion unchanged; it does not need a network download. If unavailable, install an official Lima release that includes the signed companion. Do not install the unsigned development package."),
        ("3. Install in Zen or Firefox",
         "Open about:addons in the browser. Use the gear menu → Install Add-on From File…, select the saved .xpi, and review the browser’s permissions and data-collection consent. Confirm that Lima Browser Bridge is enabled. Pin its toolbar button if desired. Install separately in each browser/profile you use. The browser checks Mozilla’s signature; never disable signature enforcement. Temporary installation through about:debugging is for development only."),
        ("4. Connect to Lima",
         "In Lima Settings → Browser Bridge, turn on Enable browser bridge, then choose Install Native Helper… and confirm. Open the browser companion popup and choose Reconnect to Lima. Back in Lima, choose Test Connection & Refresh Sites; expect End-to-end connection verified. If multiple connections appear, select the intended browser session first. Helper registration is per macOS user, not system-wide."),
        ("5. Allow reading for one site",
         "Visit a normal HTTPS page, such as https://example.com. Open the companion popup and choose Always allow reading on this site, then accept the browser’s site prompt. This exact-site grant survives browser restarts until revoked. Refresh sites in Lima, then Refresh Granted Tabs, select the tab, and choose Read Page. Only explicitly granted sites expose tab URLs/titles, visible text, links, and selection. Subdomains and different origins require separate grants. Browser-internal, HTTP, file, and private pages are excluded."),
        ("6. Choose interaction access separately",
         "Reading does not enable automatic tab changes. Interactions default to Ask every time: initiate an open, batch-open, focus, navigate, or close action in Lima, then review the pending action in the companion popup. Requests expire if unanswered. For a trusted site, choose Always allow interactions… and confirm the named site. This persists locally across restarts and covers only these tab-navigation actions—not clicks, form filling, or arbitrary scripts. Cross-site navigation needs access for both source and destination. Navigation or closing can discard unsaved work."),
        ("7. Revoke, stop, or disable",
         "Use Ask every time to remove remembered interaction access while retaining reading. Revoke all access removes reading and interaction access; refresh Lima afterward. Changing access cancels pending mutations—start a fresh action afterward. Stop in Lima or Activity Shelf cancels pending work; Escape only navigates. Cancellation cannot undo an action already dispatched. Disable browser bridge to stop connections. Remove Helper… removes Lima’s native registrations; uninstall the companion separately in about:addons. Previously shared conversation text is not erased by revocation."),
        ("8. Use browser context with AI",
         "Browser AI tools are off by default. Enable only the tools needed in Lima’s AI Tools controls: browser_tabs, browser_current, browser_read, salesforce_read_case_links, salesforce_resolve_case, salesforce_resolve_cases, browser_open_tabs, browser_focus_tab, and browser_navigate_tab. Site grants are still required. Browser content added to a conversation is sent to that conversation’s selected AI provider. Browser text is untrusted data, not instructions. Salesforce queue links are accepted only when they are unambiguous same-origin Case URLs. AI can inspect and perform granted tab navigation, but cannot click controls, fill forms, submit, or run scripts."),
        ("9. Update the companion",
         "Updating Lima does not automatically install the browser add-on. Save the newly bundled XPI and install it through about:addons in each browser/profile. Check the version shown by the browser; this release bundles companion 1.2.0. Review any new consent prompts, reconnect, and retest. Existing 1.0.0 companions retain Ask every time until upgraded and explicitly configured. The unlisted companion is distributed with Lima, not through a public AMO listing."),
        ("Troubleshooting",
         "No signed XPI: use the official release, not a development build. Signature/incompatibility error: keep signature checks enabled, update the browser, and obtain a fresh official XPI. Disconnected or native host not found: keep Lima running, enable the bridge, repair the helper from the current app location, and reconnect; restart the browser if necessary. Empty tabs/read denied: use a normal HTTPS tab, grant its exact site, and refresh. Action waiting: open the popup, review the pending request, or Stop and retry. Changed URL: refresh tabs and start a new action. Settings access modes update after Test Connection & Refresh Sites. A connection test alone does not verify every browser, AI provider, microphone, or device workflow.")
    ]
}
