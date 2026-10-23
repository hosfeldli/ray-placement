import Foundation
import RayPlacementCore

/// Native AI tools for Lima's embedded WebKit workspace. The Browser toolbar's
/// four-state control is the sole browser-specific authority; no host grants,
/// companion connection, or site adapter participates in execution.
@MainActor
enum BrowserWorkspaceAITools {
    nonisolated static let readIDs: Set<String> = [
        "browser_capabilities", "browser_tabs", "browser_current", "browser_read",
        "browser_form_read", "browser_find", "browser_wait", "browser_result_read", "browser_screenshot",
        "browser_hit_test"
    ]
    nonisolated static let navigationIDs: Set<String> = [
        "browser_new_tab", "browser_close_tab", "browser_focus_tab",
        "browser_activate", "browser_open_link", "browser_navigate", "browser_back",
        "browser_forward", "browser_reload", "browser_scroll", "browser_scan"
    ]
    nonisolated static let interactionIDs: Set<String> = [
        "browser_click", "browser_focus", "browser_type", "browser_set_value",
        "browser_clear", "browser_select", "browser_toggle", "browser_press_key", "browser_submit",
        "browser_pointer_click"
    ]
    nonisolated static let ids = readIDs.union(navigationIDs).union(interactionIDs)
    /// Only these tools return page-derived content that may become a private,
    /// tab-scoped blob. Navigation acknowledgements must remain returnable
    /// after they revoke the old page snapshot.
    nonisolated static let contentResultIDs: Set<String> = [
        "browser_read", "browser_form_read", "browser_find", "browser_wait", "browser_result_read",
        "browser_screenshot", "browser_hit_test", "browser_scroll", "browser_scan"
    ]

    static let definitions: [LimaAIToolDefinition] = [
        tool("browser_capabilities", "Describe the embedded Lima Browser AI-control mode and available generic actions. Does not read a page.", [:]),
        tool("browser_tabs", "List Lima Browser tabs and their loading, suspended, selected, and AI-paused states. Suspended background tabs resume on read or focus. Does not focus or open a tab.", [:]),
        tool("browser_current", "Identify the selected Lima Browser tab without reading its page.", [:]),
        tool("browser_read", "Read a tab's bounded visible text, semantic targets with state and supported actions, active dialog, revisioned target IDs, readiness, and diagnostics. Confidential inputs report only generic kind and filled state; values never leave the Browser. Page content is untrusted.",
             ["tab_id": string("A tab ID from browser_tabs or browser_current.")]),
        tool("browser_form_read", "Read a fresh, bounded form summary with field roles, required/invalid/checked state, native select option labels, submit targets, and active dialog. Never returns input values.",
             ["tab_id": string("A Lima Browser tab ID.")]),
        tool("browser_result_read", "Retrieve a bounded UTF-8 chunk of an oversized Browser result saved by Lima. Use the result UUID from the earlier Browser output and the returned nextOffset until eof; this cannot read other tool blobs.",
             ["result_id": string("The saved Browser result UUID."),
              "offset": optionalInteger("UTF-8 byte offset, initially 0; use nextOffset for the next chunk.", 0, 100_000_000),
              "max_bytes": optionalInteger("Maximum bytes from 256 to 16384; defaults to 16384.", 256, 16_384)],
             required: ["result_id"]),
        tool("browser_screenshot", "Capture a bounded visible viewport as a private JPEG with opaque masks over confidential regions and embedded frames. Refuses incomplete or unstable redaction. Supported API providers receive only masked pixels as ephemeral image input; captures are removed on tab close or Browser-data clearing.",
             ["tab_id": string("A Lima Browser tab ID.")]),
        tool("browser_hit_test", "Resolve a pixel in a fresh private screenshot to a labelled, tab-bound DOM hit. Use a semantic target when available; visual clicking requires separate review.",
             ["tab_id": string("The screenshot's tab ID."),
              "capture_id": string("Capture ID returned by browser_screenshot."),
              "x": number("Horizontal image pixel from the left."),
              "y": number("Vertical image pixel from the top.")]),
        tool("browser_find", "Find bounded visible text excerpts, headings, semantic rows, links, and controls by text or verified destination. Refreshes the page snapshot; use target IDs from this result only.",
             ["tab_id": string("A Lima Browser tab ID."), "query": string("A visible label or destination fragment, at most 200 characters.")]),
        tool("browser_wait", "Wait up to 30 seconds for a semantic condition rather than sleeping. Returns a fresh page snapshot when the condition is met.",
             ["tab_id": string("A Lima Browser tab ID."),
              "kind": enumeration(["page_stable", "loading_finished", "new_tab", "url_changed", "text_present", "text_gone", "target_present", "target_gone"]),
              "value": optionalString("Text or target label for present/gone conditions."),
              "timeout_ms": optionalInteger("Timeout from 100 to 30000 milliseconds.", 100, 30000)]),
        tool("browser_new_tab", "Create a Lima Browser tab with an optional verified HTTPS or loopback HTTP URL. Foreground tabs open the visible Lima Browser workspace; check browser_visible before claiming the window opened. Background pages may defer loading until read or focus.",
             ["url": optionalString("Optional HTTPS or loopback HTTP URL without embedded credentials."),
              "background": optionalBoolean("Keep the new tab in the background.")],
             risk: .navigation, required: []),
        tool("browser_close_tab", "Close one Lima Browser tab.",
             ["tab_id": string("A Lima Browser tab ID.")], risk: .navigation),
        tool("browser_focus_tab", "Select one existing Lima Browser tab and open the visible Browser workspace. Check browser_visible before claiming the window opened; this does not read the page.",
             ["tab_id": string("A Lima Browser tab ID.")], risk: .navigation),
        tool("browser_activate", "Activate a fresh link or control target. Defaults to the current tab; verified ordinary links can also open in a new or background tab. JS-only links and controls require Browser Full Control and cannot open in another tab. Download, unsafe, and sensitive targets are refused.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A target ID from the latest browser_read or browser_find."),
              "disposition": enumeration(["current_tab", "new_tab", "background_tab"])],
             risk: .navigation, required: ["tab_id", "target"]),
        tool("browser_open_link", "Open one fresh ordinary semantic link in this tab, a new tab, or a background tab. Final-sounding links require exact-call user review. Foreground navigation waits for a stable page; deferred background tabs report page_state_verified false. Download, unknown, and sensitive links are not opened.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A link target ID from the latest browser_read or browser_find."),
              "disposition": enumeration(["current_tab", "new_tab", "background_tab"])], risk: .navigation),
        tool("browser_navigate", "Navigate a Lima Browser tab to an HTTPS or loopback HTTP URL without embedded credentials and verify a newly loaded stable page.",
             ["tab_id": string("A Lima Browser tab ID."), "url": string("An HTTPS or loopback HTTP destination.")], risk: .navigation),
        tool("browser_back", "Go back in a Lima Browser tab.",
             ["tab_id": string("A Lima Browser tab ID.")], risk: .navigation),
        tool("browser_forward", "Go forward in a Lima Browser tab.",
             ["tab_id": string("A Lima Browser tab ID.")], risk: .navigation),
        tool("browser_reload", "Reload a Lima Browser tab.",
             ["tab_id": string("A Lima Browser tab ID.")], risk: .navigation),
        tool("browser_scroll", "Scroll the most relevant visible page or virtualized list region in an eligible frame by a bounded viewport fraction; prior semantic targets become stale.",
             ["tab_id": string("A Lima Browser tab ID."),
              "frame_id": optionalString("Frame ID from browser_read; defaults to main."),
              "direction": enumeration(["up", "down"]),
              "fraction": optionalNumber("Viewport fraction from 0.5 to 1.0; defaults to 0.8.", 0.5, 1)],
             risk: .navigation),
        tool("browser_scan", "Scan a visible scrollable page or list in an eligible frame over up to 20 bounded passes, collecting deduplicated text, verified links, and nonsensitive controls. Earlier target IDs are not reusable; reread before acting.",
             ["tab_id": string("A Lima Browser tab ID."),
              "frame_id": optionalString("Frame ID from browser_read; defaults to main."),
              "max_passes": optionalInteger("Maximum semantic captures from 1 to 20; defaults to 10.", 1, 20)],
             risk: .navigation),
        tool("browser_pointer_click", "Click a fresh visual hit on a canvas or nonsemantic control after exact-call user review. Requires a hit ID from browser_hit_test, never arbitrary coordinates. Reports observed effects, not transaction success.",
             ["tab_id": string("The visual hit's tab ID."),
              "hit_id": string("Fresh hit ID from browser_hit_test.")], risk: .write),
        tool("browser_click", "Click a fresh nonsensitive semantic control target. Submit controls require browser_submit. Final actions require exact-call user review; a dispatched click does not prove a remote change.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A control target ID from the latest browser_read or browser_find.")], risk: .write),
        tool("browser_focus", "Focus a fresh nonsensitive semantic control and verify that it became active.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A control target ID from the latest browser_read or browser_find.")], risk: .write),
        tool("browser_type", "Type at most 4000 UTF-8 bytes into a fresh nonsensitive text control; never use credentials or secrets.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A text-control target ID from the latest browser_read or browser_find."),
              "text": string("The text to enter.")], risk: .write),
        tool("browser_set_value", "Set a fresh nonsensitive text, number, date, time, textarea, or contenteditable control using native setters and input/change events. Returns whether the value remained after events; never use secrets.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A field target ID from a fresh Browser read."),
              "text": string("The value to set, at most 4000 UTF-8 bytes.")], risk: .write),
        tool("browser_clear", "Clear a fresh nonsensitive text or date/time control and check that it remains empty after events.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A field target ID from a fresh Browser read.")], risk: .write),
        tool("browser_select", "Select one exact option label in a fresh native single-choice select control. For ARIA comboboxes, activate the control, reread its options, and activate a fresh option target.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A native select target ID from a fresh Browser read."),
              "option": string("Exact visible option label, at most 160 characters.")], risk: .write),
        tool("browser_toggle", "Set a fresh checkbox, radio, or ARIA switch to the requested checked state. Radios cannot be unchecked directly.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A checkbox, radio, or switch target ID from a fresh Browser read."),
              "checked": ["type": "boolean", "description": "Desired checked state."]], risk: .write),
        tool("browser_press_key", "Dispatch a synthetic non-submission key to a fresh nonsensitive focusable control. Only Escape, arrows, Home, End, PageUp, and PageDown are supported; dispatch does not prove the page handled it.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A control target ID from the latest browser_read or browser_find."),
              "key": enumeration(["Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"])], risk: .write),
        tool("browser_submit", "Submit a form through a fresh nonconfidential semantic control, including after direct user entry into protected fields. Final actions require separate exact-call user review; secure-field handoff does not authorize submission, and dispatch does not prove acceptance.",
             ["tab_id": string("A Lima Browser tab ID."),
              "target": string("A control target ID from the latest browser_read or browser_find.")], risk: .write)
    ]

    private static func tool(_ id: String, _ description: String, _ properties: [String: Any],
                             risk: AILocalToolRisk = .read, required: [String]? = nil) -> LimaAIToolDefinition {
        let inferredRequired = properties.compactMap { key, value -> String? in
            let types = (value as? [String: Any])?["type"] as? [String]
            return types?.contains("null") == true ? nil : key
        }.sorted()
        return LimaAIToolDefinition(
            id: id, name: id, description: description,
            parameters: ["type": "object", "properties": properties,
                         "required": required ?? inferredRequired, "additionalProperties": false],
            risk: risk
        )
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func optionalString(_ description: String) -> [String: Any] {
        ["type": ["string", "null"], "description": description]
    }

    private static func optionalBoolean(_ description: String) -> [String: Any] {
        ["type": ["boolean", "null"], "description": description]
    }

    private static func optionalInteger(_ description: String, _ minimum: Int, _ maximum: Int) -> [String: Any] {
        ["type": ["integer", "null"], "minimum": minimum, "maximum": maximum, "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "minimum": 0, "description": description]
    }

    private static func optionalNumber(_ description: String, _ minimum: Double, _ maximum: Double) -> [String: Any] {
        ["type": ["number", "null"], "minimum": minimum, "maximum": maximum, "description": description]
    }

    private static func enumeration(_ choices: [String]) -> [String: Any] {
        ["type": "string", "enum": choices]
    }

    static func isAvailable(_ id: String, mode: BrowserAIControlMode) -> Bool {
        if id == "browser_capabilities" { return true }
        if readIDs.contains(id) { return mode.canRead }
        if navigationIDs.contains(id) { return mode.canNavigate }
        if interactionIDs.contains(id) { return mode.canInteract }
        return false
    }

    static func execute(_ call: AIOutputItem, approvalGranted: Bool = false) async -> LimaAIToolExecution {
        await execute(call, browser: .shared, approvalGranted: approvalGranted)
    }

    static func execute(_ call: AIOutputItem, browser: BrowserWorkspaceModel,
                        approvalGranted: Bool = false) async -> LimaAIToolExecution {
        let requestedTab = (try? decodedArguments(for: call)).flatMap { try? tabID($0) }
        let activityID = browser.beginAIActivity(call.name ?? "browser", tabID: requestedTab ?? browser.selectedTabID)
        let result = await executeOperation(call, browser: browser, approvalGranted: approvalGranted)
        browser.finishAIActivity(activityID, result: result)
        return result
    }

    private struct ReviewedCall {
        let toolName: String?
        let arguments: String?
        let browserID: ObjectIdentifier
        let review: BrowserCommitReview
        let createdAt: Date
    }

    /// Process-local one-call reviews. A Boolean alone cannot authorize a
    /// transaction: it must match the reviewed function call and page state.
    private static var reviewedCalls: [String: ReviewedCall] = [:]

    static func commitReview(for call: AIOutputItem) async -> BrowserCommitReview? {
        await commitReview(for: call, browser: .shared)
    }

    static func commitReview(for call: AIOutputItem,
                             browser: BrowserWorkspaceModel) async -> BrowserCommitReview? {
        guard let callID = call.callID, !callID.isEmpty else { return nil }
        let review = await currentCommitReview(for: call, browser: browser)
        if let review {
            reviewedCalls = reviewedCalls.filter {
                Date().timeIntervalSince($0.value.createdAt) < 900
            }
            reviewedCalls[callID] = ReviewedCall(
                toolName: call.name, arguments: call.arguments,
                browserID: ObjectIdentifier(browser), review: review,
                createdAt: Date()
            )
            if reviewedCalls.count > 32,
               let oldest = reviewedCalls.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                reviewedCalls.removeValue(forKey: oldest)
            }
        } else {
            reviewedCalls.removeValue(forKey: callID)
        }
        return review
    }

    private static func currentCommitReview(for call: AIOutputItem,
                                             browser: BrowserWorkspaceModel) async -> BrowserCommitReview? {
        guard browser.aiControlMode.canInteract, let arguments = try? decodedArguments(for: call),
              let id = try? tabID(arguments) else { return nil }
        if call.name == "browser_pointer_click" {
            guard let rawHitID = try? requiredString("hit_id", in: arguments),
                  let hitID = UUID(uuidString: rawHitID),
                  let hit = await browser.visualHitForReview(hitID),
                  hit.tabID == id else { return nil }
            return BrowserCommitAuthorization.visualReview(hit: hit)
        }
        guard let target = try? requiredString("target", in: arguments) else { return nil }
        let action: BrowserInteractionAction
        switch call.name {
        case "browser_submit": action = .submit
        case "browser_click", "browser_activate", "browser_open_link": action = .click
        default: return nil
        }
        return try? await browser.commitReview(id, targetID: target, action: action)
    }

    private static func requireMatchingReview(for call: AIOutputItem,
                                               browser: BrowserWorkspaceModel,
                                               approvalGranted: Bool) async throws -> Bool {
        guard ["browser_submit", "browser_click", "browser_activate",
               "browser_open_link", "browser_pointer_click"].contains(call.name ?? "") else { return false }
        let current = await currentCommitReview(for: call, browser: browser)
        let reviewed = call.callID.flatMap { reviewedCalls[$0] }
        if let reviewed {
            guard approvalGranted else { throw BrowserRuntimeError.commitApprovalRequired }
            reviewedCalls.removeValue(forKey: call.callID!)
            guard Date().timeIntervalSince(reviewed.createdAt) < 900,
                  reviewed.browserID == ObjectIdentifier(browser),
                  reviewed.toolName == call.name,
                  reviewed.arguments == call.arguments,
                  current == reviewed.review else {
                throw BrowserRuntimeError.staleTarget
            }
            return true
        } else if current != nil {
            throw BrowserRuntimeError.commitApprovalRequired
        }
        return false
    }

    private static func executeOperation(_ call: AIOutputItem, browser: BrowserWorkspaceModel,
                                         approvalGranted: Bool) async -> LimaAIToolExecution {
        guard isAvailable(call.name ?? "", mode: browser.aiControlMode) else {
            return failure(for: BrowserRuntimeError.controlDisabled).toolExecution()
        }
        do {
            let arguments = try decodedArguments(for: call)
            // A generic tool approval is not a Browser transaction token. Only
            // a fresh, exact-call review can authorize a final action below.
            let commitApproved = try await requireMatchingReview(
                for: call, browser: browser, approvalGranted: approvalGranted
            )
            switch call.name {
            case "browser_capabilities":
                return .json([
                    "runtime": "embedded_webkit",
                    "ai_control": browser.aiControlMode.rawValue,
                    "available_tools": definitions.map(\.id).filter { isAvailable($0, mode: browser.aiControlMode) }
                ])
            case "browser_tabs":
                return .json(["tabs": browser.tabs.map { tab in
                    ["tab_id": tab.id.uuidString, "title": "Browser tab",
                     "url": publicURL(tab.urlString),
                     "url_truncated": false,
                     "loading": tab.isLoading, "suspended": tab.isSuspended,
                     "selected": tab.id == browser.selectedTabID,
                     "ai_paused": browser.pausedTabIDs.contains(tab.id)] as [String: Any]
                }])
            case "browser_current":
                guard let tab = browser.selectedTab else { throw BrowserWorkspaceToolError.noSelectedTab }
                return .json(["tab_id": tab.id.uuidString, "title": "Browser tab",
                              "url": publicURL(tab.urlString),
                              "url_truncated": false,
                              "loading": tab.isLoading, "suspended": tab.isSuspended,
                              "ai_paused": browser.pausedTabIDs.contains(tab.id)],
                             browserTabID: tab.id)
            case "browser_read":
                let tab = try tabID(arguments)
                let page = try requireComplete(await browser.read(tab))
                return try encoded(page, browserTabID: tab)
            case "browser_form_read":
                let tab = try tabID(arguments)
                let page = try requireComplete(await browser.read(tab))
                return try encoded(page.formRead(), browserTabID: tab)
            case "browser_screenshot":
                let tab = try tabID(arguments)
                let capture = try await browser.screenshot(tab)
                return try encoded(capture, browserTabID: tab, browserScreenshot: capture)
            case "browser_hit_test":
                let tab = try tabID(arguments)
                let rawCaptureID = try requiredString("capture_id", in: arguments)
                guard let captureID = UUID(uuidString: rawCaptureID) else {
                    throw BrowserWorkspaceToolError.invalidArguments
                }
                let x = try requiredPixel("x", in: arguments)
                let y = try requiredPixel("y", in: arguments)
                return try encoded(await browser.hitTest(tab, captureID: captureID,
                                                         pixelX: x, pixelY: y), browserTabID: tab)
            case "browser_result_read":
                let rawID = try requiredString("result_id", in: arguments)
                guard let resultID = UUID(uuidString: rawID) else { throw BrowserWorkspaceToolError.invalidArguments }
                let offset = try optionalChunkOffset("offset", in: arguments) ?? 0
                let maximumBytes = try optionalChunkBytes("max_bytes", in: arguments) ?? 16_384
                let chunk = try await AIToolOutputStore.shared.readBrowserChunk(
                    id: resultID, offset: offset, maximumBytes: maximumBytes
                )
                guard browser.isResultAccessible(on: chunk.tabID) else {
                    throw BrowserRuntimeError.missingSnapshot
                }
                return try encoded(chunk, browserTabID: chunk.tabID)
            case "browser_find":
                let query = try requiredString("query", in: arguments)
                guard !query.isEmpty && query.count <= 200 else { throw BrowserWorkspaceToolError.invalidArguments }
                let tab = try tabID(arguments)
                let page = try requireComplete(await browser.read(tab))
                let matches = Array(page.find(query).prefix(60))
                return .json(["tab_id": tab.uuidString, "matches": try jsonObject(matches)],
                             browserTabID: tab)
            case "browser_wait":
                let tab = try tabID(arguments)
                let condition = try waitCondition(arguments)
                let timeout = try optionalInt("timeout_ms", in: arguments) ?? 10_000
                let snapshot = try requireComplete(
                    await browser.wait(tab, condition: condition, timeoutMilliseconds: timeout)
                )
                return try encoded(snapshot, browserTabID: snapshot.tabID)
            case "browser_new_tab":
                let raw = try optionalString("url", in: arguments)
                let url = try raw.map(safeURL)
                let background = try optionalBool("background", in: arguments) ?? false
                let tab = browser.newTab(url: url, foreground: !background)
                let browserVisible = background ? false : browser.revealAIForegroundTab(tab.id)
                if url != nil && !tab.isSuspended {
                    return await verifiedNavigation(browser, tabID: tab.id, after: 0,
                                                    browserVisible: browserVisible)
                }
                return .json(["requested": true, "performed": true, "tab_id": tab.id.uuidString,
                              "loading_deferred": url != nil && tab.isSuspended,
                              "page_state_verified": false, "browser_visible": browserVisible,
                              "post_action_verified": browser.tabs.contains { $0.id == tab.id }],
                             browserTabID: tab.id)
            case "browser_close_tab":
                let tab = try tabID(arguments)
                try await browser.close(tab)
                return .json(["requested": true, "performed": true, "closed_tab_id": tab.uuidString,
                              "post_action_verified": !browser.tabs.contains { $0.id == tab }])
            case "browser_focus_tab":
                let tab = try tabID(arguments)
                try browser.focus(tab)
                let browserVisible = browser.revealAIForegroundTab(tab)
                let focusedTab = try browser.tab(tab)
                return .json(["requested": true, "performed": true, "selected_tab_id": tab.uuidString,
                              "browser_visible": browserVisible,
                              "page_state_verified": focusedTab.hasLiveWebView,
                              "post_action_verified": browser.selectedTabID == tab])
            case "browser_activate":
                let tab = try tabID(arguments)
                let target = try requiredString("target", in: arguments)
                let raw = try optionalString("disposition", in: arguments) ?? "current_tab"
                guard let disposition = BrowserNavigationDisposition(rawValue: raw) else {
                    throw BrowserWorkspaceToolError.invalidArguments
                }
                let revision = try browser.tab(tab).navigationRevision
                switch try await browser.activate(tab, targetID: target, disposition: disposition,
                                                  commitApproved: commitApproved) {
                case .interacted(let outcome):
                    return try encoded(outcome, browserTabID: tab)
                case .navigated(let opened):
                    let openedTab = try browser.tab(opened)
                    let browserVisible = disposition == .backgroundTab ? false : browser.revealAIForegroundTab(opened)
                    if !openedTab.isSuspended {
                        return await verifiedNavigation(browser, tabID: opened,
                                                        after: opened == tab ? revision : 0,
                                                        disposition: raw, browserVisible: browserVisible)
                    }
                    return .json(["requested": true, "performed": true, "disposition": raw,
                                  "tab_id": opened.uuidString, "loading_deferred": true,
                                  "page_state_verified": false, "browser_visible": browserVisible,
                                  "post_action_verified": browser.tabs.contains { $0.id == opened }],
                                 browserTabID: opened)
                }
            case "browser_open_link":
                let tab = try tabID(arguments)
                let target = try requiredString("target", in: arguments)
                let raw = try requiredString("disposition", in: arguments)
                guard let disposition = BrowserNavigationDisposition(rawValue: raw) else {
                    throw BrowserWorkspaceToolError.invalidArguments
                }
                let revision = try browser.tab(tab).navigationRevision
                let opened = try await browser.openLink(tab, targetID: target,
                                                        disposition: disposition,
                                                        commitApproved: commitApproved)
                let openedTab = try browser.tab(opened)
                let browserVisible = raw == "background_tab" ? false : browser.revealAIForegroundTab(opened)
                if !openedTab.isSuspended {
                    return await verifiedNavigation(browser, tabID: opened,
                                                    after: opened == tab ? revision : 0,
                                                    disposition: raw, browserVisible: browserVisible)
                }
                return .json(["requested": true, "performed": true, "disposition": raw,
                              "tab_id": opened.uuidString, "loading_deferred": true,
                              "page_state_verified": false, "browser_visible": browserVisible,
                              "post_action_verified": browser.tabs.contains { $0.id == opened }],
                             browserTabID: opened)
            case "browser_navigate":
                let tab = try tabID(arguments)
                let url = try safeURL(requiredString("url", in: arguments))
                let revision = try browser.tab(tab).navigationRevision
                try browser.navigate(tab, to: url)
                try browser.focus(tab)
                let browserVisible = browser.revealAIForegroundTab(tab)
                return await verifiedNavigation(browser, tabID: tab, after: revision,
                                                destination: url.absoluteString,
                                                browserVisible: browserVisible)
            case "browser_back":
                let tab = try tabID(arguments)
                let revision = try browser.tab(tab).navigationRevision
                try browser.back(tab)
                try browser.focus(tab)
                return await verifiedNavigation(browser, tabID: tab, after: revision,
                                                browserVisible: browser.revealAIForegroundTab(tab))
            case "browser_forward":
                let tab = try tabID(arguments)
                let revision = try browser.tab(tab).navigationRevision
                try browser.forward(tab)
                try browser.focus(tab)
                return await verifiedNavigation(browser, tabID: tab, after: revision,
                                                browserVisible: browser.revealAIForegroundTab(tab))
            case "browser_reload":
                let tab = try tabID(arguments)
                let revision = try browser.tab(tab).navigationRevision
                try browser.reload(tab)
                try browser.focus(tab)
                return await verifiedNavigation(browser, tabID: tab, after: revision,
                                                browserVisible: browser.revealAIForegroundTab(tab))
            case "browser_scroll":
                let tab = try tabID(arguments)
                let rawDirection = try requiredString("direction", in: arguments)
                guard let direction = BrowserScrollDirection(rawValue: rawDirection) else {
                    throw BrowserWorkspaceToolError.invalidArguments
                }
                let fraction = try optionalDouble("fraction", in: arguments) ?? 0.8
                let frameID = try optionalString("frame_id", in: arguments) ?? "main"
                return try encoded(await browser.scroll(tab, direction: direction, fraction: fraction, frameID: frameID),
                                   browserTabID: tab)
            case "browser_scan":
                let tab = try tabID(arguments)
                let passes = try optionalScanPasses("max_passes", in: arguments) ?? 10
                let frameID = try optionalString("frame_id", in: arguments) ?? "main"
                let result = try await browser.scan(tab, maximumPasses: passes, frameID: frameID)
                guard !result.truncated else { throw BrowserRuntimeError.privatePageIncomplete }
                return try encoded(result, browserTabID: tab)
            case "browser_pointer_click":
                let tab = try tabID(arguments)
                let rawHitID = try requiredString("hit_id", in: arguments)
                guard let hitID = UUID(uuidString: rawHitID) else {
                    throw BrowserWorkspaceToolError.invalidArguments
                }
                return try encoded(await browser.pointerClick(tab, hitID: hitID,
                                                               commitApproved: commitApproved),
                                   browserTabID: tab)
            case "browser_click", "browser_focus", "browser_type", "browser_set_value",
                 "browser_clear", "browser_select", "browser_toggle", "browser_press_key", "browser_submit":
                let tab = try tabID(arguments)
                let target = try requiredString("target", in: arguments)
                let action: BrowserInteractionAction
                switch call.name {
                case "browser_click": action = .click
                case "browser_focus": action = .focus
                case "browser_type": action = .type
                case "browser_set_value": action = .setValue
                case "browser_clear": action = .clear
                case "browser_select": action = .select
                case "browser_toggle": action = .toggle
                case "browser_press_key": action = .pressKey
                default: action = .submit
                }
                let text: String?
                switch action {
                case .type, .setValue: text = try requiredString("text", in: arguments)
                case .select: text = try requiredString("option", in: arguments)
                case .toggle: text = try requiredBool("checked", in: arguments) ? "true" : "false"
                case .pressKey: text = try requiredString("key", in: arguments)
                default: text = nil
                }
                return try encoded(await browser.interact(tab, targetID: target, action: action, text: text,
                                                         commitApproved: commitApproved),
                                   browserTabID: tab)
            default:
                throw BrowserWorkspaceToolError.invalidArguments
            }
        } catch {
            return failure(for: error).toolExecution(state: error is CancellationError ? .cancelled : .failed)
        }
    }

    private static func verifiedNavigation(_ browser: BrowserWorkspaceModel, tabID: UUID,
                                           after revision: Int, destination: String? = nil,
                                           disposition: String? = nil,
                                           browserVisible: Bool? = nil) async -> LimaAIToolExecution {
        do {
            let snapshot = try await browser.waitForNavigation(tabID, after: revision,
                                                               timeoutMilliseconds: 15_000)
            var result: [String: Any] = [
                "state": AIToolResultState.completed.rawValue,
                "requested": true, "performed": true,
                "tab_id": tabID.uuidString,
                "post_action_verified": true, "page_state_verified": true,
                "observed_url": publicURL(snapshot.identity.url),
                "readiness": snapshot.readiness.rawValue
            ]
            if let destination { result["destination"] = publicURL(destination) }
            if let disposition { result["disposition"] = disposition }
            if let browserVisible { result["browser_visible"] = browserVisible }
            return .json(result, browserTabID: tabID)
        } catch {
            let failure = failure(for: error)
            var result: [String: Any] = [
                "state": error is CancellationError
                    ? AIToolResultState.cancelled.rawValue : AIToolResultState.partiallyCompleted.rawValue,
                "requested": true, "performed": true,
                "tab_id": tabID.uuidString,
                "post_action_verified": false, "page_state_verified": false,
                "error": failure.jsonObject
            ]
            if let destination { result["destination"] = publicURL(destination) }
            if let disposition { result["disposition"] = disposition }
            if let browserVisible { result["browser_visible"] = browserVisible }
            return .json(result, isError: true, browserTabID: tabID)
        }
    }

    static func failure(for error: Error) -> AIToolFailure {
        if error is CancellationError {
            return AIToolFailure(.cancelled, message: "The Browser action was cancelled.",
                                 recoverable: false)
        }
        if let navigationError = error as? BrowserNavigationError {
            switch navigationError {
            case .failed:
                return AIToolFailure(.navigationFailed, message: navigationError.localizedDescription,
                                     recoverable: true,
                                     nextAction: "Call browser_read to inspect the current page or navigate to another safe destination.",
                                     suggestedTools: ["browser_read", "browser_navigate"])
            case .timedOut:
                return AIToolFailure(.pageUnstable, message: navigationError.localizedDescription,
                                     recoverable: true,
                                     nextAction: "Call browser_wait for page_stable or inspect the current page with browser_read.",
                                     suggestedTools: ["browser_wait", "browser_read"])
            }
        }
        if let browserError = error as? BrowserRuntimeError {
            let message = browserError.localizedDescription
            switch browserError {
            case .missingTab:
                return AIToolFailure(.resourceUnavailable, message: message, recoverable: true,
                                     nextAction: "Call browser_tabs and use an open tab ID.",
                                     suggestedTools: ["browser_tabs"])
            case .missingSnapshot, .staleTarget:
                return AIToolFailure(.staleTarget, message: message, recoverable: true,
                                     nextAction: "Call browser_read and resolve a fresh target.",
                                     suggestedTools: ["browser_read"])
            case .pageChangedByUser:
                return AIToolFailure(.pageChangedByUser, message: message, recoverable: true,
                                     nextAction: "Call browser_read again.",
                                     suggestedTools: ["browser_read"])
            case .invalidDestination:
                return AIToolFailure(.invalidArguments, message: message, recoverable: true,
                                     nextAction: "Use HTTPS, or HTTP on localhost, 127.0.0.1, or [::1], without credentials.")
            case .noVerifiedDestination:
                return AIToolFailure(.noVerifiedDestination, message: message, recoverable: true,
                                     nextAction: "Activate it in the current tab and read the resulting page.",
                                     suggestedTools: ["browser_activate", "browser_read"])
            case .controlDisabled, .userPaused:
                return AIToolFailure(.permissionDenied, message: message, recoverable: false,
                                     nextAction: "Wait for the user to change or resume Browser AI Control.")
            case .sensitiveTarget, .screenshotProtected:
                return AIToolFailure(.permissionDenied, message: message, recoverable: false,
                                     nextAction: "Do not retry the protected action; use nonsensitive semantic content instead.")
            case .privatePageIncomplete:
                return AIToolFailure(.pageUnstable, message: message, recoverable: true,
                                     nextAction: "Wait for the page and embedded frames to settle, or complete this step directly in the Browser.",
                                     suggestedTools: ["browser_wait"])
            case .targetOccluded:
                return AIToolFailure(.targetOccluded, message: message, recoverable: true,
                                     nextAction: "Resolve the covering dialog or overlay, then call browser_read for fresh targets.",
                                     suggestedTools: ["browser_read"])
            case .commitApprovalRequired:
                return AIToolFailure(.permissionDenied, message: message, recoverable: false,
                                     nextAction: "Ask the user to approve this exact final Browser action.")
            case .targetNotInteractable:
                return AIToolFailure(.targetNotInteractable, message: message, recoverable: true,
                                     nextAction: "Call browser_read to inspect current state and choose an enabled target.",
                                     suggestedTools: ["browser_read"])
            case .unsupportedAction:
                return AIToolFailure(.unsupportedOperation, message: message, recoverable: true,
                                     nextAction: "Read the page again and choose a supported semantic action.",
                                     suggestedTools: ["browser_read"])
            }
        }
        if let toolError = error as? BrowserWorkspaceToolError {
            switch toolError {
            case .invalidArguments:
                return AIToolFailure(.invalidArguments, message: toolError.localizedDescription,
                                     recoverable: true,
                                     nextAction: "Use the Browser tool schema and supply valid arguments.",
                                     suggestedTools: ["browser_capabilities"])
            case .noSelectedTab:
                return AIToolFailure(.resourceUnavailable, message: toolError.localizedDescription,
                                     recoverable: true,
                                     nextAction: "List or open a Browser tab before reading the current tab.",
                                     suggestedTools: ["browser_tabs", "browser_new_tab"])
            }
        }
        return AIToolFailure(.resourceUnavailable, message: "The Browser action failed unexpectedly.",
                             recoverable: false)
    }

    private static func decodedArguments(for call: AIOutputItem) throws -> [String: JSONValue] {
        guard let raw = call.arguments, raw.utf8.count <= 16_384,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let definition = definitions.first(where: { $0.name == call.name }),
              let properties = definition.parameters["properties"] as? [String: Any],
              Set(arguments.keys).isSubset(of: Set(properties.keys)) else {
            throw BrowserWorkspaceToolError.invalidArguments
        }
        return arguments
    }

    private static func requiredString(_ key: String, in arguments: [String: JSONValue]) throws -> String {
        guard case .string(let value)? = arguments[key] else { throw BrowserWorkspaceToolError.invalidArguments }
        return value
    }

    private static func optionalString(_ key: String, in arguments: [String: JSONValue]) throws -> String? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func requiredPixel(_ key: String, in arguments: [String: JSONValue]) throws -> Double {
        guard case .number(let value)? = arguments[key], value.isFinite,
              value >= 0, value <= 4096 else { throw BrowserWorkspaceToolError.invalidArguments }
        return value
    }

    private static func requiredBool(_ key: String, in arguments: [String: JSONValue]) throws -> Bool {
        guard case .bool(let value)? = arguments[key] else {
            throw BrowserWorkspaceToolError.invalidArguments
        }
        return value
    }

    private static func optionalBool(_ key: String, in arguments: [String: JSONValue]) throws -> Bool? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func optionalInt(_ key: String, in arguments: [String: JSONValue]) throws -> Int? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .number(let value)? where value.isFinite && value.rounded() == value &&
            (100...30_000).contains(value): return Int(value)
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func optionalChunkOffset(_ key: String, in arguments: [String: JSONValue]) throws -> Int? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .number(let value)? where value.isFinite && value.rounded() == value &&
            (0...100_000_000).contains(value): return Int(value)
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func optionalChunkBytes(_ key: String, in arguments: [String: JSONValue]) throws -> Int? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .number(let value)? where value.isFinite && value.rounded() == value &&
            (256...16_384).contains(value): return Int(value)
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func optionalScanPasses(_ key: String, in arguments: [String: JSONValue]) throws -> Int? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .number(let value)? where value.isFinite && value.rounded() == value &&
            (1...20).contains(value): return Int(value)
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func optionalDouble(_ key: String, in arguments: [String: JSONValue]) throws -> Double? {
        switch arguments[key] {
        case nil, .null?: return nil
        case .number(let value)? where value.isFinite && (0.5...1).contains(value): return value
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func tabID(_ arguments: [String: JSONValue]) throws -> UUID {
        let value = try requiredString("tab_id", in: arguments)
        guard let id = UUID(uuidString: value) else { throw BrowserWorkspaceToolError.invalidArguments }
        return id
    }

    private static func safeURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 4_096, let url = BrowserRuntime.safeDestination(raw) else {
            throw BrowserRuntimeError.invalidDestination
        }
        return url
    }

    private static func waitCondition(_ arguments: [String: JSONValue]) throws -> BrowserWaitCondition {
        let kind = try requiredString("kind", in: arguments)
        let value = try optionalString("value", in: arguments)
        switch kind {
        case "page_stable": return .pageStable
        case "loading_finished": return .loadingFinished
        case "new_tab": return .newTab
        case "url_changed": return .urlChanged
        case "text_present": return .textPresent(try nonempty(value))
        case "text_gone": return .textGone(try nonempty(value))
        case "target_present": return .targetPresent(try nonempty(value))
        case "target_gone": return .targetGone(try nonempty(value))
        default: throw BrowserWorkspaceToolError.invalidArguments
        }
    }

    private static func nonempty(_ value: String?) throws -> String {
        guard let value, !value.isEmpty, value.count <= 200 else {
            throw BrowserWorkspaceToolError.invalidArguments
        }
        return value
    }

    private static func requireComplete(_ page: BrowserPageSnapshot) throws -> BrowserPageSnapshot {
        guard !page.diagnostics.truncated else { throw BrowserRuntimeError.privatePageIncomplete }
        return page
    }

    /// Keep path, query, fragment, and URL userinfo inside the Browser process.
    /// They can contain values echoed by a site after direct user entry.
    private static func publicURL(_ raw: String) -> String {
        guard let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty else {
            return raw == "about:blank" ? "about:blank" : "[URL hidden]"
        }
        let port = parts.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func redactURLFields(_ value: Any) -> Any {
        if let values = value as? [Any] { return values.map(redactURLFields) }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in object {
                if ["url", "observed_url", "destination", "origin"].contains(key),
                   let raw = item as? String {
                    result[key] = publicURL(raw)
                } else {
                    result[key] = redactURLFields(item)
                }
            }
            return result
        }
        return value
    }

    private static func encoded<T: Encodable>(_ value: T, browserTabID: UUID? = nil,
                                               browserScreenshot: BrowserScreenshotResult? = nil) throws -> LimaAIToolExecution {
        let object = try jsonObject(value)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return LimaAIToolExecution(output: String(decoding: data, as: UTF8.self),
                                   isError: false, browserTabID: browserTabID,
                                   browserScreenshot: browserScreenshot)
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return redactURLFields(object)
    }
}

private enum BrowserWorkspaceToolError: LocalizedError {
    case invalidArguments
    case noSelectedTab

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "The Browser tool arguments were invalid."
        case .noSelectedTab: "No Lima Browser tab is selected."
        }
    }
}
