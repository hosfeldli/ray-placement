import Foundation
import Network
import Testing
import WebKit
@testable import RayPlacement

private enum BrowserLoopbackFixtureError: Error { case didNotStart }

private final class BrowserLoopbackFixture {
    let listener: NWListener
    let url: URL

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "dev.liam.lima.browser-loopback-fixture")
        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: started.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let body = "<html><body><h1>Loopback Preview Ready</h1></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        guard started.wait(timeout: .now() + 5) == .success,
              case .ready = listener.state,
              let port = listener.port?.rawValue, port != 0,
              let destination = URL(string: "http://127.0.0.1:\(port)/") else {
            listener.cancel()
            throw BrowserLoopbackFixtureError.didNotStart
        }
        url = destination
    }

    deinit { listener.cancel() }
}

@Test func embeddedBrowserDestinationRejectsUnsafeSchemesAndCredentials() {
    #expect(BrowserRuntime.safeDestination("https://example.com/docs")?.absoluteString == "https://example.com/docs")
    for candidate in [
        "http://example.com",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "https://user:password@example.com",
        "https://",
        "data:text/html,hello"
    ] {
        #expect(BrowserRuntime.safeDestination(candidate) == nil)
    }
}

@Test func embeddedBrowserDestinationAllowsOnlyLoopbackHTTP() {
    for destination in [
        "http://localhost:5173/dashboard",
        "http://127.0.0.1:8080/",
        "http://[::1]:3000/"
    ] {
        #expect(BrowserRuntime.safeDestination(destination)?.absoluteString == destination)
    }
    for destination in [
        "http://example.com/",
        "http://localhost.evil.example/",
        "http://server.local/",
        "http://192.168.1.1/",
        "http://0.0.0.0/",
        "http://[::ffff:127.0.0.1]/",
        "http://user@localhost:5173/",
        "http://localhost:0/",
        "http://localhost:65536/"
    ] {
        #expect(BrowserRuntime.safeDestination(destination) == nil)
    }
    #expect(BrowserRuntime.addressDestination("localhost:5173")?.absoluteString == "http://localhost:5173")
    #expect(BrowserRuntime.addressDestination("127.0.0.1:8080/app")?.absoluteString == "http://127.0.0.1:8080/app")
    #expect(BrowserRuntime.addressDestination("example.com")?.absoluteString == "https://example.com")
    #expect(BrowserRuntime.addressDestination("http://example.com") == nil)
}

@Test @MainActor func embeddedBrowserNavigatesAndReadsLoopbackDevelopmentPreview() async throws {
    let server = try BrowserLoopbackFixture()
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab(url: server.url)
    let page = try await model.wait(
        tab.id, condition: .textPresent("Loopback Preview Ready"), timeoutMilliseconds: 15_000
    )
    #expect(page.identity.url.hasPrefix(server.url.absoluteString))
    #expect(page.text.contains("Loopback Preview Ready"))
    try await model.close(tab.id)
}

@Test @MainActor func embeddedBrowserNavigationPostconditionRequiresNewWebKitCompletion() async throws {
    let server = try BrowserLoopbackFixture()
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab(url: server.url)
    _ = try await model.wait(tab.id, condition: .textPresent("Loopback Preview Ready"),
                             timeoutMilliseconds: 15_000)
    let revision = tab.navigationRevision
    await #expect(throws: BrowserNavigationError.self) {
        _ = try await model.waitForNavigation(tab.id, after: revision, timeoutMilliseconds: 300)
    }
    try model.reload(tab.id)
    let page = try await model.waitForNavigation(tab.id, after: revision,
                                                 timeoutMilliseconds: 15_000)
    #expect(tab.completedNavigationRevision > revision)
    #expect(page.identity.url.hasPrefix(server.url.absoluteString))
    #expect(page.text.contains("Loopback Preview Ready"))
    try await model.close(tab.id)
}

@Test @MainActor func embeddedBrowserToolsReportLoadedAndDeferredPostconditions() async throws {
    let server = try BrowserLoopbackFixture()
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    func call(_ name: String, _ arguments: [String: Any]) throws -> AIOutputItem {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return AIOutputItem(phase: .completed, apiType: "function_call", name: name,
                            arguments: String(decoding: data, as: UTF8.self))
    }
    func object(_ execution: LimaAIToolExecution) throws -> [String: Any] {
        let data = try #require(execution.output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let navigation = await BrowserWorkspaceAITools.execute(try call("browser_navigate", [
        "tab_id": tab.id.uuidString, "url": server.url.absoluteString
    ]), browser: model)
    #expect(!navigation.isError)
    let loaded = try object(navigation)
    #expect(loaded["post_action_verified"] as? Bool == true)
    #expect(loaded["page_state_verified"] as? Bool == true)
    #expect((loaded["observed_url"] as? String)?.hasPrefix(server.url.absoluteString) == true)

    let background = await BrowserWorkspaceAITools.execute(try call("browser_new_tab", [
        "url": server.url.absoluteString, "background": true
    ]), browser: model)
    #expect(!background.isError)
    let deferred = try object(background)
    #expect(deferred["post_action_verified"] as? Bool == true)
    #expect(deferred["page_state_verified"] as? Bool == false)
    #expect(deferred["loading_deferred"] as? Bool == true)
    let backgroundIDString = try #require(deferred["tab_id"] as? String)
    let backgroundID = try #require(UUID(uuidString: backgroundIDString))
    try await model.close(backgroundID)
    try await model.close(tab.id)
}

@Test @MainActor func aiBrowserToolsRevealForegroundTabsButNotBackgroundTabs() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    var revealed: [UUID] = []
    model.onAIForegroundTab = { id in
        revealed.append(id)
        return true
    }
    func call(_ name: String, _ arguments: [String: Any]) throws -> AIOutputItem {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return AIOutputItem(phase: .completed, apiType: "function_call", name: name,
                            arguments: String(decoding: data, as: UTF8.self))
    }
    func object(_ execution: LimaAIToolExecution) throws -> [String: Any] {
        let data = try #require(execution.output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    let foreground = try object(await BrowserWorkspaceAITools.execute(
        try call("browser_new_tab", [:]), browser: model
    ))
    let foregroundIDString = try #require(foreground["tab_id"] as? String)
    let foregroundID = try #require(UUID(uuidString: foregroundIDString))
    #expect(foreground["browser_visible"] as? Bool == true)
    #expect(revealed == [foregroundID])

    let background = try object(await BrowserWorkspaceAITools.execute(
        try call("browser_new_tab", ["background": true]), browser: model
    ))
    let backgroundIDString = try #require(background["tab_id"] as? String)
    let backgroundID = try #require(UUID(uuidString: backgroundIDString))
    #expect(background["browser_visible"] as? Bool == false)
    #expect(revealed == [foregroundID])

    let focused = try object(await BrowserWorkspaceAITools.execute(
        try call("browser_focus_tab", ["tab_id": backgroundID.uuidString]), browser: model
    ))
    #expect(focused["browser_visible"] as? Bool == true)
    #expect(focused["post_action_verified"] as? Bool == true)
    #expect(revealed == [foregroundID, backgroundID])
    try await model.close(backgroundID)
    try await model.close(foregroundID)
}

@Test @MainActor func embeddedBrowserFailuresOfferMachineActionableRepair() throws {
    let stale = BrowserWorkspaceAITools.failure(for: BrowserRuntimeError.staleTarget)
    #expect(stale.code == .staleTarget)
    #expect(stale.recoverable)
    #expect(stale.suggestedTools == ["browser_read"])
    let execution = stale.toolExecution()
    #expect(execution.isError)
    let data = try #require(execution.output.data(using: .utf8))
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let error = try #require(payload["error"] as? [String: Any])
    #expect(payload["state"] as? String == "failed")
    #expect(error["code"] as? String == "stale_target")
    #expect(error["next_action"] as? String == "Call browser_read and resolve a fresh target.")
    #expect((error["suggested_tools"] as? [String]) == ["browser_read"])

    let sensitive = BrowserWorkspaceAITools.failure(for: BrowserRuntimeError.sensitiveTarget)
    #expect(sensitive.code == .permissionDenied)
    #expect(!sensitive.recoverable)
    let destination = BrowserWorkspaceAITools.failure(for: BrowserRuntimeError.invalidDestination)
    #expect(destination.code == .invalidArguments)
    #expect(destination.recoverable)
    let failedNavigation = BrowserWorkspaceAITools.failure(for: BrowserNavigationError.failed)
    #expect(failedNavigation.code == .navigationFailed)
    #expect(failedNavigation.suggestedTools == ["browser_read", "browser_navigate"])
    let stalledNavigation = BrowserWorkspaceAITools.failure(for: BrowserNavigationError.timedOut)
    #expect(stalledNavigation.code == .pageUnstable)
    #expect(stalledNavigation.suggestedTools == ["browser_wait", "browser_read"])
}

@Test func embeddedBrowserOpenLinkRejectsDownloadsUnknownAndSensitiveTargets() {
    func link(_ relationship: String, sensitive: Bool = false) -> BrowserTarget {
        BrowserTarget(
            id: "link", role: "link", label: "Download report",
            destination: "https://example.com/report", relationship: relationship,
            x: 0, y: 0, width: 100, height: 20, frameID: "main", sensitive: sensitive
        )
    }
    #expect(BrowserRuntime.safeLinkDestination(link("normal"))?.absoluteString == "https://example.com/report")
    #expect(BrowserRuntime.safeLinkDestination(link("new_tab")) != nil)
    #expect(BrowserRuntime.safeLinkDestination(link("download")) == nil)
    #expect(BrowserRuntime.safeLinkDestination(link("unknown")) == nil)
    #expect(BrowserRuntime.safeLinkDestination(link("normal", sensitive: true)) == nil)
}

@Test func embeddedBrowserFrameGeometryClipsTransformedTargets() {
    let target = BrowserTarget(
        id: "nested", role: "button", label: "Nested control",
        destination: nil, relationship: nil,
        x: 10, y: 20, width: 100, height: 40,
        frameID: "nested-frame", sensitive: false
    )
    let geometry = BrowserFrameGeometry(
        x: 100, y: 80, scaleX: 1.5, scaleY: 1.5,
        clipX: 120, clipY: 120, clipWidth: 80, clipHeight: 50
    )
    let visible = geometry.visibleTargetBounds(
        target, viewport: CGRect(x: 0, y: 0, width: 800, height: 600)
    )
    #expect(visible == CGRect(x: 120, y: 120, width: 80, height: 50))
}

@Test func embeddedBrowserFindReturnsBoundedPlainTextContextWithoutInventedTarget() {
    let snapshot = BrowserPageSnapshot(
        identity: BrowserPageIdentity(
            documentID: "plain", routeGeneration: 0, mutationRevision: 0,
            userRevision: 0, snapshotRevision: 1, url: "https://example.com"
        ),
        readiness: .readyWithContent, title: "Plain Text",
        text: String(repeating: "prefix ", count: 1_000) +
            "The installation process is complete. " +
            String(repeating: "suffix ", count: 1_000),
        links: [], controls: [], headings: [], rows: [],
        diagnostics: BrowserDiagnostics(
            textLength: 14_000, linkCount: 0, controlCount: 0, headingCount: 0,
            semanticRowCount: 0, shadowRootCount: 0, frameCount: 1,
            quietMS: 600, truncated: false
        )
    )
    let match = snapshot.find("installation").first
    #expect(match?.role == "text")
    #expect(match?.targetID == nil)
    #expect(match?.text.contains("installation process") == true)
    #expect((match?.text.count ?? 0) <= 400)
}

@Test func embeddedBrowserTargetsExpireWhenSnapshotChanges() async throws {
    let runtime = BrowserRuntime()
    let tab = UUID()
    let identity = BrowserPageIdentity(
        documentID: "document-1", routeGeneration: 0, mutationRevision: 1,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com"
    )
    let target = BrowserTarget(
        id: "t_1_0", role: "link", label: "Documentation",
        destination: "https://example.com/docs", relationship: "normal",
        x: 10, y: 20, width: 100, height: 30, frameID: "main", sensitive: false
    )
    let diagnostics = BrowserDiagnostics(
        textLength: 13, linkCount: 1, controlCount: 0, headingCount: 0,
        semanticRowCount: 0, shadowRootCount: 0, frameCount: 1, quietMS: 600, truncated: false
    )
    let snapshot = BrowserPageSnapshot(
        identity: identity, readiness: .readyWithContent, title: "Example",
        text: "Documentation", links: [target], controls: [], headings: [], rows: [],
        diagnostics: diagnostics
    )
    await runtime.replace(snapshot, for: tab)
    let resolved = try await runtime.resolve(tabID: tab, targetID: target.id, link: true)
    #expect(resolved.0 == identity)
    #expect(resolved.1 == target)
    #expect(snapshot.find("docs").first?.targetID == target.id)

    let changed = BrowserPageSnapshot(
        identity: BrowserPageIdentity(
            documentID: "document-1", routeGeneration: 1, mutationRevision: 2,
            userRevision: 0, snapshotRevision: 2, url: "https://example.com/next"
        ),
        readiness: .readyEmpty, title: "Next", text: "",
        links: [], controls: [], headings: [], rows: [], diagnostics: diagnostics
    )
    await runtime.replace(changed, for: tab)
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await runtime.resolve(tabID: tab, targetID: target.id, link: true)
    }
}

@Test func embeddedBrowserTargetsUseTheirOwnFrameIdentity() async throws {
    let runtime = BrowserRuntime()
    let tab = UUID()
    let main = BrowserPageIdentity(
        documentID: "main", routeGeneration: 0, mutationRevision: 1,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com"
    )
    let child = BrowserPageIdentity(
        documentID: "child", routeGeneration: 2, mutationRevision: 9,
        userRevision: 0, snapshotRevision: 4, url: "https://other.example/frame"
    )
    let target = BrowserTarget(
        id: "t_child_4_0", role: "link", label: "Frame link",
        destination: "https://example.com/docs", relationship: "normal",
        x: 0, y: 0, width: 80, height: 20, frameID: "child-frame", sensitive: false
    )
    let snapshot = BrowserPageSnapshot(
        identity: main, readiness: .readyWithContent, title: "Main", text: "Frame link",
        links: [target], controls: [], headings: [], rows: [],
        diagnostics: BrowserDiagnostics(
            textLength: 10, linkCount: 1, controlCount: 0, headingCount: 0,
            semanticRowCount: 0, shadowRootCount: 0, frameCount: 2,
            quietMS: 600, truncated: false
        )
    )
    await runtime.replace(snapshot, frameIdentities: ["child-frame": child], for: tab)
    let resolved = try await runtime.resolve(tabID: tab, targetID: target.id, link: true)
    #expect(resolved.0 == child)
    await runtime.replace(snapshot, for: tab)
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await runtime.resolve(tabID: tab, targetID: target.id, link: true)
    }
}

@Test func embeddedBrowserSensitiveTargetNeverResolves() async throws {
    let runtime = BrowserRuntime()
    let tab = UUID()
    let target = BrowserTarget(
        id: "t_1_0", role: "textbox", label: "Password",
        destination: nil, relationship: nil, x: 0, y: 0, width: 100, height: 20,
        frameID: "main", sensitive: true
    )
    let snapshot = BrowserPageSnapshot(
        identity: BrowserPageIdentity(
            documentID: "document-1", routeGeneration: 0, mutationRevision: 1,
            userRevision: 0, snapshotRevision: 1, url: "https://example.com"
        ),
        readiness: .readyWithContent, title: "Example", text: "",
        links: [], controls: [target], headings: [], rows: [],
        diagnostics: BrowserDiagnostics(
            textLength: 0, linkCount: 0, controlCount: 1, headingCount: 0,
            semanticRowCount: 0, shadowRootCount: 0, frameCount: 1, quietMS: 600, truncated: false
        )
    )
    await runtime.replace(snapshot, for: tab)
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await runtime.resolve(tabID: tab, targetID: target.id, link: false)
    }
}

@Test @MainActor func browserAIControlModesGateTheWholeToolFamily() {
    for mode in BrowserAIControlMode.allCases {
        #expect(BrowserWorkspaceAITools.isAvailable("browser_capabilities", mode: mode))
        #expect(BrowserWorkspaceAITools.isAvailable("browser_read", mode: mode) == mode.canRead)
        #expect(BrowserWorkspaceAITools.isAvailable("browser_screenshot", mode: mode) == mode.canRead)
        #expect(BrowserWorkspaceAITools.isAvailable("browser_result_read", mode: mode) == mode.canRead)
        #expect(BrowserWorkspaceAITools.isAvailable("browser_open_link", mode: mode) == mode.canNavigate)
        #expect(BrowserWorkspaceAITools.isAvailable("browser_scan", mode: mode) == mode.canNavigate)
        #expect(BrowserWorkspaceAITools.isAvailable("browser_focus", mode: mode) == mode.canInteract)
        #expect(BrowserWorkspaceAITools.isAvailable("browser_press_key", mode: mode) == mode.canInteract)
        #expect(BrowserWorkspaceAITools.isAvailable("browser_submit", mode: mode) == mode.canInteract)
    }
    #expect(!BrowserWorkspaceAITools.isAvailable("browser_scan_report", mode: .fullControl))
    let resultRead = BrowserWorkspaceAITools.definitions.first { $0.id == "browser_result_read" }
    #expect(resultRead?.risk == .read)
}

@Test @MainActor func embeddedBrowserOpenLinkMarksDeferredBackgroundTab() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let source = model.newTab()
    source.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    source.webView.loadHTMLString(
        "<a href='https://example.com/docs'>Documentation</a>",
        baseURL: URL(string: "https://example.com")!
    )
    let page = try await model.wait(
        source.id, condition: .targetPresent("Documentation"), timeoutMilliseconds: 15_000
    )
    let link = try #require(page.links.first { $0.label == "Documentation" })
    let destinationID = try await model.openLink(
        source.id, targetID: link.id, disposition: .backgroundTab
    )
    let destination = try model.tab(destinationID)
    #expect(model.selectedTabID == source.id)
    #expect(destination.isSuspended)
    #expect(!destination.hasLiveWebView)
    #expect(destination.urlString == "https://example.com/docs")
    #expect(model.automation?.destinationTabID == destinationID)
    #expect(model.automation?.title.contains("background tab") == true)
    try await model.close(destinationID)
    try await model.close(source.id)
}

@Test @MainActor func embeddedBrowserPoolsBackgroundViewsAndRevokesSuspendedTargets() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let first = model.newTab()
    let originalView = first.webView
    _ = try await model.read(first.id)
    for _ in 0..<8 {
        let tab = model.newTab()
        _ = try await model.read(tab.id)
    }
    #expect(model.tabs.count == 9)
    #expect(model.liveWebViewCount <= 6)
    #expect(first.isSuspended)
    #expect(!first.hasLiveWebView)
    #expect(!model.isResultAccessible(on: first.id))

    try model.focus(first.id)
    #expect(!first.hasLiveWebView) // Focusing a blank tab does not instantiate WebKit.
    #expect(!model.isResultAccessible(on: first.id))
    _ = try await model.read(first.id)
    #expect(first.hasLiveWebView)
    #expect(first.activeWebView !== originalView)
    #expect(model.liveWebViewCount <= 6)
    #expect(model.isResultAccessible(on: first.id))
    for tab in model.tabs.map(\.id) { try await model.close(tab) }
}

@Test @MainActor func embeddedBrowserConcurrentReadsKeepLiveViewCap() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tabs = (0..<9).map { _ in model.newTab() }
    let reads = tabs.map { tab in
        Task { @MainActor in try? await model.read(tab.id) }
    }
    for read in reads { _ = await read.value }
    #expect(model.liveWebViewCount <= 6)
    #expect(model.tabs.filter(\.isSuspended).count >= 3)
    for tab in tabs { try await model.close(tab.id) }
}

@Test @MainActor func embeddedBrowserNavigationRevokesResultsAndDoesNotInventSuspendedHistory() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    _ = try await model.read(tab.id)
    #expect(model.isResultAccessible(on: tab.id))

    let destination = try #require(URL(string: "https://127.0.0.1/lima-test"))
    try model.navigate(tab.id, to: destination)
    #expect(!model.isResultAccessible(on: tab.id))
    #expect(tab.urlString == destination.absoluteString)
    #expect(model.liveWebViewCount == 1)

    #expect(tab.suspend())
    #expect(throws: BrowserRuntimeError.self) { try model.back(tab.id) }
    #expect(throws: BrowserRuntimeError.self) { try model.forward(tab.id) }
    try model.focus(tab.id)
    #expect(tab.hasLiveWebView)
    #expect(model.liveWebViewCount == 1)
    #expect(tab.urlString == destination.absoluteString)
    try await model.close(tab.id)
}

@Test @MainActor func embeddedBrowserRapidUserTakeoverRequiresFreshTargets() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    tab.webView.loadHTMLString(
        "<button id='continue' onclick=\"this.setAttribute('aria-pressed','true')\">Continue</button>",
        baseURL: URL(string: "https://example.com")!
    )
    // WebKit process startup can exceed five seconds in the parallel full suite;
    // this test measures target revocation, not page-load latency.
    let original = try await model.wait(tab.id, condition: .targetPresent("Continue"), timeoutMilliseconds: 15_000)
    let target = try #require(original.controls.first { $0.label == "Continue" })
    model.pauseAI(on: tab.id)
    #expect(!model.isResultAccessible(on: tab.id))
    try model.resumeAI(on: tab.id)
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.interact(tab.id, targetID: target.id, action: .click)
    }
    let fresh = try await model.read(tab.id)
    #expect(fresh.controls.first { $0.label == "Continue" }?.id != target.id)
    #expect(model.isResultAccessible(on: tab.id))
    try await model.close(tab.id)
}

@Test @MainActor func embeddedBrowserModeChangesRevokePageResultsUntilReread() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    _ = try await model.read(tab.id)
    #expect(model.isResultAccessible(on: tab.id))
    model.aiControlMode = .off
    #expect(!model.isResultAccessible(on: tab.id))
    model.aiControlMode = .fullControl
    #expect(!model.isResultAccessible(on: tab.id))
    _ = try await model.read(tab.id)
    #expect(model.isResultAccessible(on: tab.id))
    try await model.close(tab.id)
}

@Test @MainActor func embeddedBrowserFixtureModelDoesNotChangeSharedAIControlPreference() {
    let defaults = LimaTestEnvironment.userDefaults
    let before = defaults.string(forKey: "limaBrowserAIControlMode")
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = before == BrowserAIControlMode.readOnly.rawValue ? .fullControl : .readOnly
    #expect(defaults.string(forKey: "limaBrowserAIControlMode") == before)
}

@Test @MainActor func embeddedBrowserScanSchemasAndAccumulatorAreBounded() throws {
    let scan = try #require(BrowserWorkspaceAITools.definitions.first { $0.id == "browser_scan" })
    let scroll = try #require(BrowserWorkspaceAITools.definitions.first { $0.id == "browser_scroll" })
    let scanRequired = try #require(scan.parameters["required"] as? [String])
    let scrollRequired = try #require(scroll.parameters["required"] as? [String])
    #expect(scanRequired == ["tab_id"])
    #expect(scrollRequired == ["direction", "tab_id"])

    let identity = BrowserPageIdentity(
        documentID: "scan", routeGeneration: 0, mutationRevision: 0,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com"
    )
    let safeLink = BrowserTarget(
        id: "link", role: "link", label: "Guide", destination: "https://example.com/guide",
        relationship: "normal", x: 0, y: 0, width: 80, height: 20,
        frameID: "main", sensitive: false
    )
    let sensitiveControl = BrowserTarget(
        id: "password", role: "textbox", label: "Password", destination: nil,
        relationship: nil, x: 0, y: 0, width: 80, height: 20,
        frameID: "main", sensitive: true
    )
    let diagnostics = BrowserDiagnostics(
        textLength: 11, linkCount: 1, controlCount: 1, headingCount: 0,
        semanticRowCount: 0, shadowRootCount: 0, frameCount: 1, quietMS: 600, truncated: false
    )
    let first = BrowserPageSnapshot(
        identity: identity, readiness: .readyWithContent, title: "Scan",
        text: "First\nSecond", links: [safeLink], controls: [sensitiveControl],
        headings: [], rows: [BrowserSemanticItem(
            stableKey: "row_1", role: "row", text: "First item",
            linkTargetIDs: ["link"], controlTargetIDs: []
        )], diagnostics: diagnostics
    )
    let second = BrowserPageSnapshot(
        identity: identity, readiness: .readyWithContent, title: "Scan",
        text: "Second\nThird", links: [safeLink], controls: [sensitiveControl],
        headings: [], rows: [
            BrowserSemanticItem(stableKey: "row_1", role: "row", text: "First item",
                                linkTargetIDs: ["link"], controlTargetIDs: []),
            BrowserSemanticItem(stableKey: "row_2", role: "row", text: "Second item",
                                linkTargetIDs: [], controlTargetIDs: [])
        ], diagnostics: diagnostics
    )
    var accumulator = BrowserScanAccumulator()
    #expect(accumulator.add(first) == 4)
    #expect(accumulator.add(second) == 2)
    let result = accumulator.result(tabID: UUID(), captures: 2, reachedEnd: true,
                                    stoppedForNoNewContent: false)
    #expect(result.lines == ["First", "Second", "Third"])
    #expect(result.rows.map(\.stableKey) == ["row_1", "row_2"])
    #expect(result.links.count == 1)
    #expect(result.controls.isEmpty)
    #expect(!result.truncated)
}

@Test func embeddedBrowserGoneWaitsRequireSemanticReadiness() {
    let snapshot = BrowserPageSnapshot(
        identity: BrowserPageIdentity(
            documentID: "loading", routeGeneration: 0, mutationRevision: 0,
            userRevision: 0, snapshotRevision: 1, url: "https://example.com"
        ),
        readiness: .loading, title: "Loading", text: "", links: [], controls: [],
        headings: [], rows: [], diagnostics: BrowserDiagnostics(
            textLength: 0, linkCount: 0, controlCount: 0, headingCount: 0,
            semanticRowCount: 0, shadowRootCount: 0, frameCount: 1,
            quietMS: 0, truncated: false
        )
    )
    #expect(!BrowserWaitCondition.textGone("Completed").matches(snapshot, initialURL: snapshot.identity.url))
    #expect(!BrowserWaitCondition.targetGone("Continue").matches(snapshot, initialURL: snapshot.identity.url))
    #expect(!BrowserWaitCondition.loadingFinished.matches(snapshot, initialURL: snapshot.identity.url, isLoading: true))
    let partial = BrowserPageSnapshot(
        identity: snapshot.identity, readiness: .readyWithContent, title: "Partial",
        text: "Visible main frame", links: [], controls: [], headings: [], rows: [],
        diagnostics: BrowserDiagnostics(
            textLength: 18, linkCount: 0, controlCount: 0, headingCount: 0,
            semanticRowCount: 0, shadowRootCount: 0, frameCount: 2,
            quietMS: 600, truncated: true
        )
    )
    #expect(!BrowserWaitCondition.textGone("Completed").matches(partial, initialURL: partial.identity.url))
    #expect(!BrowserWaitCondition.targetGone("Continue").matches(partial, initialURL: partial.identity.url))
    #expect(BrowserWaitCondition.loadingFinished.matches(partial, initialURL: partial.identity.url, isLoading: false))
    #expect(!BrowserWaitCondition.loadingFinished.matches(partial, initialURL: partial.identity.url, isLoading: true))
}

@Test @MainActor func embeddedBrowserWaitForNewTabReturnsTheOpenedTabIdentity() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let first = model.newTab()
    first.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    first.webView.loadHTMLString("<h1>Main</h1>", baseURL: URL(string: "https://example.com")!)
    let waiting = Task {
        try await model.wait(first.id, condition: .newTab, timeoutMilliseconds: 5_000)
    }
    try await Task.sleep(for: .milliseconds(200))
    let opened = model.newTab()
    opened.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
    opened.webView.loadHTMLString("<h1>New tab</h1>", baseURL: URL(string: "https://example.com/new")!)
    let result = try await waiting.value
    #expect(result.tabID == opened.id)
    try await model.close(opened.id)
    try await model.close(first.id)
}

@Test func embeddedBrowserAggregateWaitsForEveryFrameToSettle() {
    let identity = BrowserPageIdentity(
        documentID: "main", routeGeneration: 0, mutationRevision: 0,
        userRevision: 0, snapshotRevision: 1, url: "https://example.com"
    )
    let diagnostics = BrowserDiagnostics(
        textLength: 0, linkCount: 0, controlCount: 0, headingCount: 0,
        semanticRowCount: 0, shadowRootCount: 0, frameCount: 1,
        quietMS: 700, truncated: false
    )
    let main = BrowserPageSnapshot(
        identity: identity, readiness: .readyEmpty, title: "Main",
        text: "", links: [], controls: [], headings: [], rows: [],
        diagnostics: diagnostics
    )
    func child(_ readiness: BrowserReadiness, text: String = "") -> BrowserPageSnapshot {
        var snapshot = BrowserPageSnapshot(
            identity: BrowserPageIdentity(
                documentID: "child", routeGeneration: 0, mutationRevision: 0,
                userRevision: 0, snapshotRevision: 1, url: "https://other.example"
            ),
            readiness: readiness, title: "Child", text: text,
            links: [], controls: [], headings: [], rows: [], diagnostics: diagnostics
        )
        snapshot.frameID = "child"
        return snapshot
    }
    let missing = BrowserPageSnapshot.aggregate(main, children: [], expectedFrameCount: 2)
    #expect(missing.readiness == .unstable)
    #expect(missing.diagnostics.truncated)
    #expect(!BrowserWaitCondition.pageStable.matches(missing, initialURL: identity.url))

    let hydrating = BrowserPageSnapshot.aggregate(
        main, children: [child(.hydrating)], expectedFrameCount: 2
    )
    #expect(hydrating.readiness == .hydrating)
    #expect(!BrowserWaitCondition.pageStable.matches(hydrating, initialURL: identity.url))

    let ready = BrowserPageSnapshot.aggregate(
        main, children: [child(.readyWithContent, text: "Ready")], expectedFrameCount: 2
    )
    #expect(ready.readiness == .readyWithContent)
    #expect(BrowserWaitCondition.pageStable.matches(ready, initialURL: identity.url))
}

@Test @MainActor func embeddedBrowserWebKitReadsLinksShadowControlsAndRejectsStaleTargets() async throws {
    let tab = BrowserTab(configuration: WKWebViewConfiguration())
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><head><title>Local Browser Test</title></head><body>
        <h1>Ready</h1>
        <a href="https://example.com/docs">Documentation</a>
        <ul><li id="guide-row"><a href="https://example.com/row">Row Guide</a></li></ul>
        <button id="ordinary" onclick="document.body.dataset.clicked = 'yes'">Continue</button>
        <button id="destructive" onclick="document.body.dataset.deleted = 'yes'">Delete account</button>
        <div role="dialog" aria-label="Delete workspace"><button id="confirm" onclick="document.body.dataset.deleted = 'yes'">Confirm</button></div>
        <div data-destructive="true"><button id="danger" onclick="document.body.dataset.deleted = 'yes'">Proceed</button></div>
        <section aria-label="Delete workspace"><button id="section-confirm" onclick="document.body.dataset.deleted = 'yes'">Continue</button></section>
        <form aria-label="Transfer funds"><button id="form-confirm" type="submit">Continue</button></form>
        <input type="password" aria-label="Password">
        <input type="checkbox" aria-label="Subscribe">
        <span id="query-label">Project query</span>
        <input type="text" aria-labelledby="query-label" value="private-should-not-be-returned">
        <div id="shadow"></div>
        <script>
          const root = document.getElementById('shadow').attachShadow({mode: 'open'});
          root.innerHTML = '<a href="https://example.com/shadow">Shadow Guide</a>';
        </script>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)

    let world = WKContentWorld.world(name: BrowserSemanticScript.world)
    var snapshot: BrowserPageSnapshot?
    var lastFailure = "No snapshot attempt"
    for _ in 0..<100 {
        do {
            let value = try await tab.webView.callAsyncJavaScript(
                BrowserSemanticScript.snapshot, arguments: [:], in: nil, contentWorld: world
            )
            guard let raw = value as? String, let data = raw.data(using: .utf8) else {
                lastFailure = "Snapshot did not return a string"
                try await Task.sleep(for: .milliseconds(25))
                continue
            }
            let decoded = try JSONDecoder().decode(BrowserPageSnapshot.self, from: data)
            if decoded.headings.contains("Ready") {
                snapshot = decoded
                break
            }
            lastFailure = "Headings were \(decoded.headings); title was \(decoded.title)"
        } catch {
            lastFailure = String(describing: error)
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    if snapshot == nil { Issue.record("WebKit snapshot unavailable: \(lastFailure)") }
    let page = try #require(snapshot)
    #expect(page.links.contains { $0.label == "Documentation" && $0.destination == "https://example.com/docs" })
    #expect(page.links.contains { $0.label == "Shadow Guide" && $0.destination == "https://example.com/shadow" })
    #expect(page.text.contains("Shadow Guide"))
    let rowLink = try #require(page.links.first { $0.label == "Row Guide" })
    #expect(page.rows.contains { $0.text == "Row Guide" && $0.linkTargetIDs.contains(rowLink.id) })
    #expect(page.find("Ready").contains { $0.role == "heading" && $0.targetID == nil })
    #expect(page.find("Row Guide").contains { $0.role == "li" && $0.stableKey != nil })
    #expect(page.diagnostics.semanticRowCount >= 1)
    #expect(page.controls.contains { $0.label == "Continue" && !$0.sensitive })
    #expect(page.controls.filter { $0.label == "Continue" && $0.sensitive }.count == 2)
    #expect(page.controls.contains { $0.label == "Password" && $0.sensitive })
    #expect(page.controls.contains { $0.label == "Delete account" && $0.sensitive })
    #expect(page.controls.contains { $0.label == "Confirm" && $0.sensitive })
    #expect(page.controls.contains { $0.label == "Proceed" && $0.sensitive })
    #expect(page.controls.contains { $0.label == "Subscribe" && !$0.sensitive })
    #expect(page.controls.contains { $0.label == "Project query" })
    #expect(!page.text.contains("private-should-not-be-returned"))
    #expect(page.diagnostics.shadowRootCount >= 1)

    let button = try #require(page.controls.first { $0.label == "Continue" })
    let args: [String: Any] = [
        "documentID": page.identity.documentID,
        "routeGeneration": page.identity.routeGeneration,
        "mutationRevision": page.identity.mutationRevision,
        "userRevision": page.identity.userRevision,
        "snapshotRevision": page.identity.snapshotRevision,
        "targetID": button.id,
        "action": "click",
        "text": ""
    ]
    let password = try #require(page.controls.first { $0.label == "Password" })
    var passwordArgs = args
    passwordArgs["targetID"] = password.id
    passwordArgs["action"] = "type"
    passwordArgs["text"] = "never-enter-this"
    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action, arguments: passwordArgs, in: nil, contentWorld: world
        )
    }
    let checkbox = try #require(page.controls.first { $0.label == "Subscribe" })
    var checkboxArgs = args
    checkboxArgs["targetID"] = checkbox.id
    checkboxArgs["action"] = "type"
    checkboxArgs["text"] = "not-a-checkbox-value"
    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action, arguments: checkboxArgs, in: nil, contentWorld: world
        )
    }
    let contextual = try #require(page.controls.first { $0.label == "Continue" && $0.sensitive })
    var contextualArgs = args
    contextualArgs["targetID"] = contextual.id
    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action, arguments: contextualArgs, in: nil, contentWorld: world
        )
    }
    let destructive = try #require(page.controls.first { $0.label == "Delete account" })
    var destructiveArgs = args
    destructiveArgs["targetID"] = destructive.id
    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action, arguments: destructiveArgs, in: nil, contentWorld: world
        )
    }
    let confirmation = try #require(page.controls.first { $0.label == "Confirm" })
    var confirmationArgs = args
    confirmationArgs["targetID"] = confirmation.id
    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action, arguments: confirmationArgs, in: nil, contentWorld: world
        )
    }
    let query = try #require(page.controls.first { $0.label == "Project query" })
    var typeArgs = args
    typeArgs["targetID"] = query.id
    typeArgs["action"] = "type"
    typeArgs["text"] = "search phrase"
    let typeJSON = try #require(try await tab.webView.callAsyncJavaScript(
        BrowserSemanticScript.action, arguments: typeArgs, in: nil, contentWorld: world
    ) as? String)
    let typeData = try #require(typeJSON.data(using: .utf8))
    let typeAcknowledgement = try #require(JSONSerialization.jsonObject(with: typeData) as? [String: Any])
    #expect(typeAcknowledgement["verified"] as? Bool == true)
    #expect(!typeJSON.contains("search phrase"))
    #expect(try await tab.webView.evaluateJavaScript("document.querySelector('input[aria-labelledby]').value") as? String == "search phrase")

    _ = try await tab.webView.callAsyncJavaScript(
        BrowserSemanticScript.action, arguments: args, in: nil, contentWorld: world
    )
    let clicked = try await tab.webView.evaluateJavaScript("document.body.dataset.clicked") as? String
    #expect(clicked == "yes")
    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action, arguments: args, in: nil, contentWorld: world
        )
    }

    let routeJSON = try #require(try await tab.webView.callAsyncJavaScript(
        BrowserSemanticScript.snapshot, arguments: [:], in: nil, contentWorld: world
    ) as? String)
    let routeBefore = try JSONDecoder().decode(BrowserPageSnapshot.self,
                                               from: try #require(routeJSON.data(using: .utf8)))
    let routeButton = try #require(routeBefore.controls.first { $0.label == "Continue" })
    var routeArgs = args
    routeArgs["documentID"] = routeBefore.identity.documentID
    routeArgs["routeGeneration"] = routeBefore.identity.routeGeneration
    routeArgs["mutationRevision"] = routeBefore.identity.mutationRevision
    routeArgs["userRevision"] = routeBefore.identity.userRevision
    routeArgs["snapshotRevision"] = routeBefore.identity.snapshotRevision
    routeArgs["targetID"] = routeButton.id
    _ = try await tab.webView.evaluateJavaScript("history.pushState({}, '', '#next')")
    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action, arguments: routeArgs, in: nil, contentWorld: world
        )
    }
    let changedJSON = try #require(try await tab.webView.callAsyncJavaScript(
        BrowserSemanticScript.snapshot, arguments: [:], in: nil, contentWorld: world
    ) as? String)
    let routeAfter = try JSONDecoder().decode(BrowserPageSnapshot.self,
                                              from: try #require(changedJSON.data(using: .utf8)))
    #expect(routeAfter.identity.routeGeneration > routeBefore.identity.routeGeneration)
    #expect(routeAfter.identity.url.hasSuffix("#next"))
}

@Test @MainActor func embeddedBrowserFocusAndBoundedKeyDispatchProtectSensitiveTargets() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <button id="menu" aria-label="Menu" onkeydown="document.body.dataset.key = event.key" onclick="history.pushState({}, '', '#opened'); document.body.append('Opened')">Menu</button>
        <input type="password" aria-label="Password">
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var page: BrowserPageSnapshot?
    for _ in 0..<100 {
        if let snapshot = try? await model.read(tab.id),
           snapshot.controls.contains(where: { $0.label == "Menu" }) {
            page = snapshot
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let snapshot = try #require(page)
    let menu = try #require(snapshot.controls.first { $0.label == "Menu" })
    let focus = try await model.interact(tab.id, targetID: menu.id, action: .focus)
    #expect(focus.postActionVerified)
    let key = try await model.interact(tab.id, targetID: menu.id, action: .pressKey, text: "Escape")
    #expect(key.performed)
    #expect(!key.postActionVerified)
    #expect(try await tab.webView.evaluateJavaScript("document.body.dataset.key") as? String == "Escape")
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.interact(tab.id, targetID: menu.id, action: .pressKey, text: "Enter")
    }
    let password = try #require(snapshot.controls.first { $0.label == "Password" })
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.interact(tab.id, targetID: password.id, action: .pressKey, text: "Escape")
    }
    let refreshed = try await model.read(tab.id)
    let routeButton = try #require(refreshed.controls.first { $0.label == "Menu" })
    let click = try await model.interact(tab.id, targetID: routeButton.id, action: .click)
    #expect(click.postActionVerified)
    #expect(click.pageChanged)
    #expect(click.routeChangeDetected)
    try await model.close(tab.id)
}

@Test @MainActor func embeddedBrowserScreenshotIsPrivateBoundedAndRejectsSensitivePage() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .readOnly
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body><h1>Screenshot Fixture</h1></body></html>
        """, baseURL: URL(string: "https://example.com")!)
    var ready = false
    for _ in 0..<100 {
        if let page = try? await model.read(tab.id), page.headings.contains("Screenshot Fixture") {
            ready = true
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ready)
    try await Task.sleep(for: .milliseconds(200))
    let capture = try await model.screenshot(tab.id)
    #expect(capture.mediaType == "image/jpeg")
    #expect((1...1280).contains(capture.pixelWidth))
    #expect((1...900).contains(capture.pixelHeight))
    #expect((1...4_000_000).contains(capture.byteCount))
    #expect(model.isScreenshotCurrent(capture))
    let imageBase64 = try await BrowserScreenshotStore.shared.providerBase64(for: capture)
    #expect(Data(base64Encoded: imageBase64)?.count == capture.byteCount)
    #expect(FileManager.default.fileExists(atPath: capture.fileURL.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: capture.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    _ = try await tab.webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<input type=\"password\" aria-label=\"Password\">')")
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await model.screenshot(tab.id)
    }
    try await model.close(tab.id)
    #expect(!model.isScreenshotCurrent(capture))
    #expect(!FileManager.default.fileExists(atPath: capture.fileURL.path))
    await #expect(throws: BrowserRuntimeError.self) {
        _ = try await BrowserScreenshotStore.shared.providerBase64(for: capture)
    }
}

@Test @MainActor func embeddedBrowserReadsAndActsInSameAndOpaqueFrames() async throws {
    let model = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
    model.aiControlMode = .fullControl
    let tab = model.newTab()
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body><h1>Main Frame</h1>
        <iframe srcdoc="<a href='https://example.com/same'>Same Frame Link</a>"></iframe>
        <iframe sandbox="allow-scripts" srcdoc="<input type='checkbox' aria-label='Opaque Frame Action'><a href='https://example.com/opaque'>Opaque Frame Link</a><div role='list' aria-label='Frame Items' style='height:100px;width:200px;overflow-y:auto'><div style='height:1000px'>Frame content</div></div>"></iframe>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)

    var combined: BrowserPageSnapshot?
    for _ in 0..<160 {
        if let page = try? await model.read(tab.id),
           page.links.contains(where: { $0.label == "Same Frame Link" }),
           page.links.contains(where: { $0.label == "Opaque Frame Link" }),
           page.controls.contains(where: { $0.label == "Opaque Frame Action" }) {
            combined = page
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let page = try #require(combined)
    let same = try #require(page.links.first { $0.label == "Same Frame Link" })
    let opaque = try #require(page.links.first { $0.label == "Opaque Frame Link" })
    #expect(same.frameID != "main")
    #expect(opaque.frameID != "main")
    #expect(same.frameID != opaque.frameID)
    #expect(page.frameContexts?.contains { $0.id == same.frameID } == true)
    #expect(page.frameContexts?.contains { $0.id == opaque.frameID && $0.origin == "opaque" } == true)
    #expect(page.diagnostics.frameCount >= 3)
    let button = try #require(page.controls.first { $0.label == "Opaque Frame Action" })
    var frameGeometryReady = false
    for _ in 0..<50 {
        if let raw = try? await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.frameGeometry,
            arguments: ["frameID": button.frameID], in: nil,
            contentWorld: .world(name: BrowserSemanticScript.world)
        ) as? String, !raw.isEmpty {
            frameGeometryReady = true
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(frameGeometryReady)
    let result = try await model.interact(tab.id, targetID: button.id, action: .click)
    #expect(result.performed)
    #expect(result.postActionVerified)
    #expect(!result.routeChangeDetected)
    let overlay = try #require(model.automation?.overlayBounds)
    #expect(overlay.minX > button.x)
    #expect(overlay.minY > button.y)
    #expect(overlay.width > 0 && overlay.height > 0)
    let frame = try #require(tab.frameInfo(for: button.frameID))
    let marker = try await tab.webView.callAsyncJavaScript(
        "return document.querySelector('input[type=checkbox]').checked;", arguments: [:], in: frame,
        contentWorld: .world(name: BrowserSemanticScript.world)
    ) as? Bool
    #expect(marker == true)
    let scrolled = try await model.scroll(tab.id, direction: .down, frameID: button.frameID)
    #expect(scrolled.performed)
    #expect(scrolled.frameID == button.frameID)
    #expect(scrolled.regionLabel == "Frame Items")
    #expect(scrolled.after > scrolled.before)
    await #expect(throws: Error.self) {
        _ = try await model.scroll(tab.id, direction: .down, frameID: "not-a-registered-frame")
    }
    try await model.close(tab.id)
}

@Test @MainActor func embeddedBrowserScrollsGenericVisibleRegionAndInvalidatesTargets() async throws {
    let tab = BrowserTab(configuration: WKWebViewConfiguration())
    tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    tab.webView.loadHTMLString("""
        <!doctype html><html><body>
        <h1>Scrollable test</h1>
        <div id="items" role="list" aria-label="Items"
             style="height:120px;width:300px;overflow-y:auto">
          <button id="top">Top control</button>
          <div style="height:1000px">Repeated content</div>
          <button id="bottom">Bottom control</button>
        </div>
        </body></html>
        """, baseURL: URL(string: "https://example.com")!)
    let world = WKContentWorld.world(name: BrowserSemanticScript.world)
    var page: BrowserPageSnapshot?
    for _ in 0..<100 {
        if let raw = try? await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.snapshot, arguments: [:], in: nil, contentWorld: world
        ) as? String, let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(BrowserPageSnapshot.self, from: data),
           decoded.headings.contains("Scrollable test") {
            page = decoded
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let snapshot = try #require(page)
    let target = try #require(snapshot.controls.first { $0.label == "Top control" })
    let scrollRaw = try await tab.webView.callAsyncJavaScript(
        BrowserSemanticScript.scroll,
        arguments: [
            "documentID": snapshot.identity.documentID,
            "routeGeneration": snapshot.identity.routeGeneration,
            "userRevision": snapshot.identity.userRevision,
            "direction": "down",
            "fraction": 0.8
        ],
        in: nil, contentWorld: world
    ) as? String
    let data = try #require(scrollRaw?.data(using: .utf8))
    let outcome = try JSONDecoder().decode(BrowserScrollOutcome.self, from: data)
    #expect(outcome.performed)
    #expect(outcome.after > outcome.before)
    #expect(outcome.regionLabel == "Items")
    #expect(outcome.availableRegions >= 1)

    await #expect(throws: Error.self) {
        _ = try await tab.webView.callAsyncJavaScript(
            BrowserSemanticScript.action,
            arguments: [
                "documentID": snapshot.identity.documentID,
                "routeGeneration": snapshot.identity.routeGeneration,
                "mutationRevision": snapshot.identity.mutationRevision,
                "userRevision": snapshot.identity.userRevision,
                "snapshotRevision": snapshot.identity.snapshotRevision,
                "targetID": target.id,
                "action": "click",
                "text": ""
            ],
            in: nil, contentWorld: world
        )
    }
}
