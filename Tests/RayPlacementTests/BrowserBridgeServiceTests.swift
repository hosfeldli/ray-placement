import Foundation
import Network
import Testing
@testable import RayPlacement
import RayPlacementCore

@MainActor
private final class BridgeServiceFixture {
    let root = URL(fileURLWithPath: "/private/tmp/lbs-\(UUID().uuidString.prefix(12))")
    let suite = "bridge-service-\(UUID())"
    let defaults: UserDefaults
    let registry = TaskRegistry()
    let service: BrowserBridgeService
    var channel: BrowserBridgeChannel?
    var messages: [BrowserBridgeMessage] = []
    var origins: [JSONValue] = [.string("https://example.com/*")]
    var tabs: [JSONValue] = [
        .object(["id": .number(1), "url": .string("https://example.com/page"), "title": .string("Example")])
    ]
    var capabilities: [JSONValue] = []
    var nextTabID = 10
    var autoStatus = true
    var autoTabs = true

    func sent(_ command: String) -> [BrowserBridgeMessage] {
        messages.filter { $0.kind == "request" && $0.command == command }
    }

    init() {
        defaults = UserDefaults(suiteName: suite)!
        service = BrowserBridgeService(defaults: defaults, socketURL: root.appendingPathComponent("socket"), registry: registry)
    }

    func connect() async throws {
        service.enabled = true
        try await wait { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("socket").path) }
        let connection = NWConnection(to: .unix(path: root.appendingPathComponent("socket").path), using: .tcp)
        let channel = BrowserBridgeChannel(connection: connection, receive: { [weak self] message in
            await self?.record(message)
        }, disconnected: {})
        self.channel = channel
        channel.start()
        channel.send(.init(kind: "hello", command: "connect", arguments: ["extensionID": .string(BrowserBridgeIdentity.extensionID)]))
        try await wait { self.service.sessions.count == 1 }
    }

    private func record(_ message: BrowserBridgeMessage) {
        messages.append(message)
        guard message.kind == "request" else { return }
        if message.command == "bridge.status" && autoStatus {
            channel?.send(.init(id: message.id, kind: "response", command: message.command,
                                result: .object(["origins": .array(origins), "capabilities": .array(capabilities)])))
        } else if message.command == "browser.tabs" && autoTabs {
            channel?.send(.init(id: message.id, kind: "response", command: message.command,
                                result: .object(["tabs": .array(tabs), "restrictedToGrantedSites": .bool(true)])))
        } else if message.command == "browser.open_tabs" {
            guard case .array(let values)? = message.arguments["urls"] else { return }
            let urls = values.compactMap { value -> String? in
                guard case .string(let url) = value else { return nil }
                return url
            }
            for url in urls {
                tabs.append(.object(["id": .number(Double(nextTabID)), "url": .string(url),
                                    "title": .string("Opened tab"), "windowID": .number(2)]))
                nextTabID += 1
            }
            channel?.send(.init(id: message.id, kind: "response", command: message.command,
                                result: .object(["opened": .number(Double(urls.count)), "failed": .number(0),
                                                 "background": message.arguments["background"] ?? .bool(false)])))
        }
    }

    func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw BrowserBridgeError.timeout
    }

    func close() {
        channel?.cancel()
        service.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test @MainActor func browserBridgeServiceCorrelatesResponsesAndKeepsContentOutOfTaskMetadata() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()
    let request = Task { try await fixture.service.request("browser.read", arguments: ["tabID": .number(1)]) }
    try await fixture.wait { fixture.sent("browser.read").count == 1 }
    let message = try #require(fixture.sent("browser.read").first)
    fixture.channel?.send(.init(id: message.id, kind: "response", command: "wrong.command", result: .string("ignored")))
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(fixture.registry.activeTasks.count == 1)
    let page: JSONValue = .object(["url": .string("https://example.com/page"), "text": .string("private page text")])
    fixture.channel?.send(.init(id: message.id, kind: "response", command: message.command, result: page))
    #expect(try await request.value == page)
    #expect(fixture.registry.activeTasks.isEmpty)
    #expect(fixture.registry.recentTasks.count == 1)
    let task = try #require(fixture.registry.recentTasks.first)
    #expect(task.state == .completed)
    #expect(!task.compactDetail.contains("private"))
}

@Test @MainActor func browserBridgeBatchOpenUsesSignedLegacyWireAndReturnsObservedIdentityPerURL() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()

    let urls = ["https://example.com/case/one", "https://example.com/case/two"]
    let result = try await fixture.service.openTabs(urls: urls, background: true, reuseExisting: false)
    let message = try #require(fixture.sent("browser.open_tabs").first)
    #expect(fixture.sent("browser.open_tabs").count == 1)
    #expect(Set(message.arguments.keys) == Set(["urls", "background"]))
    #expect(message.arguments["urls"] == .array(urls.map(JSONValue.string)))
    #expect(message.arguments["background"] == .bool(true))

    guard case .object(let fields) = result, case .array(let rows)? = fields["results"] else {
        Issue.record("Expected one tab identity result per requested URL")
        return
    }
    #expect(fields["opened"] == .number(2))
    #expect(fields["failed"] == .number(0))
    #expect(rows.count == 2)
    #expect(rows.compactMap { row -> Double? in
        guard case .object(let values) = row, case .number(let id)? = values["tabID"] else { return nil }
        return id
    } == [10.0, 11.0])
}

@Test @MainActor func browserBridgeBatchReuseMatchesCanonicalURLsAndDeduplicatesNewTabs() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    fixture.tabs = [.object(["id": .number(1), "url": .string("https://example.com/case#old"), "title": .string("Lightning Experience")])]
    try await fixture.connect()

    let urls = ["https://example.com/case#requested", "https://example.com/new#one", "https://example.com/new#two"]
    let result = try await fixture.service.openTabs(urls: urls, background: true, reuseExisting: true)
    let message = try #require(fixture.sent("browser.open_tabs").first)
    #expect(message.arguments["urls"] == .array([.string("https://example.com/new#one")]))
    guard case .object(let fields) = result, case .array(let rows)? = fields["results"],
          rows.count == 3, case .object(let existing) = rows[0],
          case .object(let firstNew) = rows[1], case .object(let reusedNew) = rows[2] else {
        Issue.record("Expected per-request identity results for existing and new tabs")
        return
    }
    #expect(existing["tabID"] == .number(1))
    #expect(existing["reusedExisting"] == .bool(true))
    #expect(existing["finalURL"] == .string("https://example.com/case#old"))
    #expect(firstNew["tabID"] == .number(10))
    #expect(firstNew["openedNew"] == .bool(true))
    #expect(firstNew["reusedExisting"] == .bool(false))
    #expect(reusedNew["tabID"] == .number(10))
    #expect(reusedNew["openedNew"] == .bool(false))
    #expect(reusedNew["reusedExisting"] == .bool(true))
}

@Test @MainActor func browserBridgeActionJournalUsesOnlyDestinationMetadata() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()

    fixture.origins = [.string("https://source.example/*"), .string("https://destination.example/*")]
    let request = Task {
        try await fixture.service.request(
            "browser.navigate",
            arguments: [
                "tabID": .number(3),
                "expectedURL": .string("https://source.example/private-case"),
                "url": .string("https://destination.example/investigation")
            ]
        )
    }
    try await fixture.wait { fixture.sent("browser.navigate").count == 1 }
    let task = try #require(fixture.registry.activeTasks.first)
    #expect(task.title == "AI browser navigation")
    #expect(task.detail == "Navigate tab · destination.example")
    #expect(!task.compactDetail.contains("private-case"))
    fixture.channel?.send(.init(
        id: try #require(fixture.sent("browser.navigate").first).id,
        kind: "response",
        command: "browser.navigate",
        result: .object(["navigated": .bool(true)])
    ))
    _ = try await request.value
    #expect(fixture.registry.recentTasks.first?.state == .completed)
}

@Test @MainActor func browserBridgeInteractionRequiresAdvertisedCapability() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()

    let unsupported = Task { try await fixture.service.requireInteractionCapability() }
    try await fixture.wait { fixture.sent("bridge.status").count == 1 }
    do {
        try await unsupported.value
        Issue.record("A companion without an interaction capability unexpectedly passed")
    } catch {
        #expect(error.localizedDescription.contains("compatible signed Browser Bridge page-session update"))
    }

    fixture.capabilities = [.string("browser_interaction_v1")]
    let legacy = Task { try await fixture.service.requireInteractionCapability() }
    try await fixture.wait { fixture.sent("bridge.status").count == 2 }
    do {
        try await legacy.value
        Issue.record("A legacy interaction companion unexpectedly passed the snapshot-target capability gate")
    } catch {
        #expect(error.localizedDescription.contains("page-session update"))
    }

    fixture.capabilities = [.string("browser_interaction_v1"), .string("browser_targets_v2")]
    let supported = Task { try await fixture.service.requireInteractionCapability() }
    try await fixture.wait { fixture.sent("bridge.status").count == 3 }
    try await supported.value
}

@Test @MainActor func salesforceLookupRejectsUnreadyAndUnverifiedEmptySnapshots() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()

    func reply(_ index: Int, status: String?, links: [JSONValue]) throws {
        let message = try #require(fixture.sent("browser.read").dropFirst(index).first)
        var page: [String: JSONValue] = [
            "url": .string("https://example.com/page"),
            "links": .array(links)
        ]
        if let status { page["status"] = .string(status) }
        fixture.channel?.send(.init(id: message.id, kind: "response", command: message.command,
                                    result: .object(page)))
    }

    let timedOut = Task { try await fixture.service.readCaseLinks(tabID: 1) }
    try await fixture.wait { fixture.sent("browser.read").count == 1 }
    try reply(0, status: "timed_out", links: [])
    do {
        _ = try await timedOut.value
        Issue.record("A timed-out report was treated as empty")
    } catch {
        #expect(error.localizedDescription.contains("not reached a verified ready state"))
    }

    let legacyEmpty = Task { try await fixture.service.readCaseLinks(tabID: 1) }
    try await fixture.wait { fixture.sent("browser.read").count == 2 }
    try reply(1, status: nil, links: [])
    do {
        _ = try await legacyEmpty.value
        Issue.record("An unverified legacy empty snapshot was treated as an empty report")
    } catch {
        #expect(error.localizedDescription.contains("zero links alone is not an empty report"))
    }

    let visibleLink: JSONValue = .object([
        "href": .string("https://example.com/lightning/r/Case/500000000000001/view"),
        "text": .string("Case 00012345")
    ])
    let ready = Task { try await fixture.service.readCaseLinks(tabID: 1) }
    try await fixture.wait { fixture.sent("browser.read").count == 3 }
    try reply(2, status: "ready_with_content", links: [visibleLink])
    guard case .object(let fields) = try await ready.value else {
        Issue.record("The ready report did not return structured case links")
        return
    }
    #expect(fields["scope"] == .string("visible_snapshot_only"))
    #expect(fields["readiness"] == .string("ready_with_content"))
    #expect(fields["complete"] == .bool(false))
    guard case .array(let cases)? = fields["cases"] else {
        Issue.record("The ready report did not return a cases array")
        return
    }
    #expect(cases.count == 1)

    let missing = Task { try await fixture.service.resolveCase(number: "99999999", tabID: 1) }
    try await fixture.wait { fixture.sent("browser.read").count == 4 }
    try reply(3, status: "ready_with_content", links: [visibleLink])
    do {
        _ = try await missing.value
        Issue.record("A Case absent from visible links was treated as definitively not found")
    } catch {
        #expect(error.localizedDescription.contains("currently visible report links"))
    }
}

@Test @MainActor func browserBridgeGenericScanRequiresCapabilityAndVerifiesBoundedGrantedResult() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()
    let arguments: [String: JSONValue] = ["tabID": .number(1)]

    do {
        _ = try await fixture.service.request("browser.scan", arguments: arguments)
        Issue.record("A companion without generic scan capability was allowed to scan")
    } catch BrowserBridgeError.scanUnavailable {
        // The older signed companion must not be treated as scan-capable.
    }
    #expect(fixture.sent("browser.scan").isEmpty)

    fixture.capabilities = [.string("browser_scan_v1")]
    let page: JSONValue = .object([
        "url": .string("https://example.com/page"),
        "status": .string("ready_with_content"),
        "scope": .string("bounded_viewport_scan"),
        "complete": .bool(false),
        "text": .string("Visible virtualized rows"),
        "links": .array([]),
        "controls": .array([]),
        "scrollPasses": .number(2),
        "endReached": .bool(false),
        "restored": .bool(true),
        "truncated": .bool(true)
    ])
    let accepted = Task { try await fixture.service.request("browser.scan", arguments: arguments) }
    try await fixture.wait { fixture.sent("browser.scan").count == 1 }
    let first = try #require(fixture.sent("browser.scan").first)
    fixture.channel?.send(.init(id: first.id, kind: "response", command: first.command, result: page))
    #expect(try await accepted.value == page)
    #expect(fixture.registry.activeTasks.isEmpty)

    var falseComplete = page
    if case .object(var fields) = falseComplete {
        fields["complete"] = .bool(true)
        falseComplete = .object(fields)
    }
    let malformed = Task { try await fixture.service.request("browser.scan", arguments: arguments) }
    try await fixture.wait { fixture.sent("browser.scan").count == 2 }
    let second = try #require(fixture.sent("browser.scan").last)
    fixture.channel?.send(.init(id: second.id, kind: "response", command: second.command, result: falseComplete))
    do {
        _ = try await malformed.value
        Issue.record("A falsely complete browser scan was accepted")
    } catch BrowserBridgeError.invalidResponse {
        // A scan can never claim complete site coverage.
    }

    let revoked = Task { try await fixture.service.request("browser.scan", arguments: arguments) }
    try await fixture.wait { fixture.sent("browser.scan").count == 3 }
    fixture.origins = []
    let third = try #require(fixture.sent("browser.scan").last)
    fixture.channel?.send(.init(id: third.id, kind: "response", command: third.command, result: page))
    do {
        _ = try await revoked.value
        Issue.record("A scan result escaped after exact-site access was revoked")
    } catch {
        #expect(error.localizedDescription.contains("Site access is not granted"))
    }
}

@Test @MainActor func browserBridgeActivityStopCancelsThePendingRequestAndSendsCancelFrame() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()
    let request = Task { try await fixture.service.request("browser.open", arguments: ["url": .string("https://example.com"), "active": .bool(false)]) }
    try await fixture.wait { fixture.sent("browser.open").count == 1 }
    let task = try #require(fixture.registry.activeTasks.first)
    fixture.registry.cancel(task.id)
    do { _ = try await request.value; Issue.record("Cancelled request unexpectedly succeeded") }
    catch { #expect(error is CancellationError) }
    try await fixture.wait { fixture.messages.contains { $0.kind == "cancel" } }
    #expect(fixture.registry.task(id: task.id)?.state == .cancelled)
    #expect(fixture.messages.last?.id == fixture.sent("browser.open").first?.id)
}

@Test @MainActor func browserBridgeStopResumesPendingWorkAndSecondInstanceCannotRemoveSocket() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()
    let other = BrowserBridgeService(defaults: fixture.defaults, socketURL: fixture.root.appendingPathComponent("socket"), registry: TaskRegistry())
    other.start()
    #expect(other.sessions.isEmpty)
    other.stop()
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("socket").path))
    fixture.autoTabs = false
    let request = Task { try await fixture.service.request("browser.tabs") }
    try await fixture.wait { fixture.sent("browser.tabs").count == 1 }
    fixture.service.enabled = false
    do { _ = try await request.value; Issue.record("Disabled bridge unexpectedly returned data") }
    catch { #expect(error is BrowserBridgeError) }
    #expect(fixture.registry.activeTasks.isEmpty)
    #expect(fixture.registry.recentTasks.first?.state == .failed)
    #expect(fixture.service.sessions.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("socket").path))
}

@Test @MainActor func browserBridgeGrantPolicyKeepsExactSitesUsableAndInteractionsExactOnly() throws {
    let policy = try BrowserBridgeGrantPolicy.parse([
        .string("https://example.com/*"),
        .string("https://*/*")
    ])
    try policy.require("https://example.com/page", broadEnabled: false)
    #expect(policy.allows("https://example.com/page", broadEnabled: false))
    #expect(!policy.allows("https://other.example/page", broadEnabled: false))
    #expect(policy.allows("https://other.example/page", broadEnabled: true))
    do {
        try policy.require("https://other.example/page", broadEnabled: false)
        Issue.record("Broad-only site unexpectedly passed with the experiment off")
    } catch {
        #expect(error.localizedDescription.contains("all-HTTPS"))
    }
    do {
        try policy.require("https://other.example/page", broadEnabled: true, interaction: true)
        Issue.record("Broad grant unexpectedly enabled browser interaction")
    } catch {
        #expect(error.localizedDescription.contains("Site access is not granted"))
    }
    do {
        _ = try BrowserBridgeGrantPolicy.parse([.string("http://*/*")])
        Issue.record("Unsupported host permission unexpectedly passed")
    } catch {
        #expect(error.localizedDescription.contains("unsupported host grant"))
    }
}

@Test func browserBridgeRejectionMessagesAreActionableAndDoNotEchoUnknownCodes() {
    let expired = BrowserBridgeError.rejected("approval_expired").localizedDescription
    #expect(expired.contains("approval expired"))
    #expect(expired.contains("toolbar popup"))
    let changed = BrowserBridgeError.rejected("page_changed").localizedDescription
    #expect(changed.contains("Refresh the granted tabs"))
    let unknown = BrowserBridgeError.rejected("unexpected_secret_from_page").localizedDescription
    #expect(!unknown.contains("unexpected_secret_from_page"))
}

@Test @MainActor func browserBridgeTabsFilterBroadOnlyAndPrivateTabsUntilEnabled() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    fixture.origins = [.string("https://example.com/*"), .string("https://*/*")]
    fixture.tabs = [
        .object(["id": .number(1), "url": .string("https://example.com/page")]),
        .object(["id": .number(2), "url": .string("https://other.example/page")]),
        .object(["id": .number(3), "url": .string("https://example.com/private"), "incognito": .bool(true)])
    ]
    try await fixture.connect()

    let exactOnly = try await fixture.service.request("browser.tabs")
    guard case .object(let first) = exactOnly, case .array(let firstTabs)? = first["tabs"] else {
        Issue.record("Expected filtered browser tab list")
        return
    }
    #expect(firstTabs.count == 1)
    fixture.defaults.set(true, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)

    let broad = try await fixture.service.request("browser.tabs")
    guard case .object(let second) = broad, case .array(let broadTabs)? = second["tabs"] else {
        Issue.record("Expected broad browser tab list")
        return
    }
    #expect(broadTabs.count == 2)
    #expect(!broadTabs.contains { tab in
        guard case .object(let info) = tab else { return false }
        return info["incognito"] == .bool(true)
    })
    fixture.defaults.set(false, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    let offAgain = try await fixture.service.request("browser.tabs")
    guard case .object(let third) = offAgain, case .array(let thirdTabs)? = third["tabs"] else {
        Issue.record("Expected filtered browser tab list after disabling broad access")
        return
    }
    #expect(thirdTabs.count == 1)
}

@Test @MainActor func browserBridgeBroadReadRequiresExperimentAndRechecksRevocation() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    fixture.origins = [.string("https://example.com/*"), .string("https://*/*")]
    fixture.tabs = [.object(["id": .number(2), "url": .string("https://other.example/page")])]
    try await fixture.connect()

    do {
        _ = try await fixture.service.request("browser.read", arguments: ["tabID": .number(2)])
        Issue.record("Broad-only page unexpectedly read with the experiment off")
    } catch {
        #expect(error.localizedDescription.contains("all-HTTPS"))
    }
    #expect(fixture.sent("browser.read").isEmpty)

    fixture.defaults.set(true, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    let request = Task { try await fixture.service.request("browser.read", arguments: ["tabID": .number(2)]) }
    try await fixture.wait { fixture.sent("browser.read").count == 1 }
    fixture.origins = [.string("https://example.com/*")]
    let message = try #require(fixture.sent("browser.read").first)
    fixture.channel?.send(.init(id: message.id, kind: "response", command: message.command,
                                result: .object(["url": .string("https://other.example/page"),
                                                 "text": .string("not for AI after revocation")])))
    do {
        _ = try await request.value
        Issue.record("Revoked broad grant unexpectedly returned page content")
    } catch {
        #expect(error.localizedDescription.contains("Site access is not granted"))
    }
}

@Test @MainActor func browserBridgeBroadGrantCannotAuthorizeClickOrPrivateRead() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    fixture.origins = [.string("https://*/*")]
    fixture.tabs = [.object(["id": .number(4), "url": .string("https://other.example/private"),
                              "incognito": .bool(true)])]
    fixture.defaults.set(true, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    try await fixture.connect()

    do {
        _ = try await fixture.service.request("browser.click", arguments: [
            "tabID": .number(4), "expectedURL": .string("https://other.example/private"),
            "selector": .string("#continue")
        ])
        Issue.record("Broad grant unexpectedly authorized click")
    } catch {
        #expect(error.localizedDescription.contains("Site access is not granted"))
    }
    #expect(fixture.sent("browser.click").isEmpty)
    do {
        _ = try await fixture.service.request("browser.read", arguments: ["tabID": .number(4)])
        Issue.record("Private tab unexpectedly read")
    } catch {
        #expect(error.localizedDescription.contains("Site access is not granted"))
    }
    #expect(fixture.sent("browser.read").isEmpty)
}

@Test @MainActor func browserBridgeBroadNavigationNeedsExperimentAndStillUsesOneCompanionAction() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    fixture.origins = [.string("https://example.com/*"), .string("https://*/*")]
    try await fixture.connect()
    let arguments: [String: JSONValue] = [
        "tabID": .number(1),
        "expectedURL": .string("https://example.com/page"),
        "url": .string("https://other.example/destination")
    ]
    do {
        _ = try await fixture.service.request("browser.navigate", arguments: arguments)
        Issue.record("Broad-only destination unexpectedly navigated with the experiment off")
    } catch {
        #expect(error.localizedDescription.contains("all-HTTPS"))
    }
    #expect(fixture.sent("browser.navigate").isEmpty)

    fixture.defaults.set(true, forKey: AIComputerActionPolicy.broadBrowserGrantsKey)
    let request = Task { try await fixture.service.request("browser.navigate", arguments: arguments) }
    try await fixture.wait { fixture.sent("browser.navigate").count == 1 }
    let message = try #require(fixture.sent("browser.navigate").first)
    let result: JSONValue = .object(["id": .number(1), "url": .string("https://other.example/destination")])
    fixture.channel?.send(.init(id: message.id, kind: "response", command: message.command, result: result))
    #expect(try await request.value == result)
    #expect(fixture.sent("browser.navigate").count == 1)
}
