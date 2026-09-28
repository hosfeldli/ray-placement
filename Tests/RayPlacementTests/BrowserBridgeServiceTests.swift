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

    private func record(_ message: BrowserBridgeMessage) { messages.append(message) }

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
    try await fixture.wait { fixture.messages.count == 1 }
    let message = try #require(fixture.messages.first)
    fixture.channel?.send(.init(id: message.id, kind: "response", command: "wrong.command", result: .string("ignored")))
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(fixture.registry.activeTasks.count == 1)
    fixture.channel?.send(.init(id: message.id, kind: "response", command: message.command, result: .string("private page text")))
    #expect(try await request.value == .string("private page text"))
    #expect(fixture.registry.activeTasks.isEmpty)
    let task = try #require(fixture.registry.recentTasks.first)
    #expect(task.state == .completed)
    #expect(!task.compactDetail.contains("private"))
}

@Test @MainActor func browserBridgeBatchOpenUsesOneBoundedRequest() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()

    let urls = ["https://example.com/case/one", "https://example.com/case/two"]
    let request = Task { try await fixture.service.openTabs(urls: urls, background: true) }
    try await fixture.wait { fixture.messages.count == 1 }
    let message = try #require(fixture.messages.first)
    #expect(message.command == "browser.open_tabs")
    #expect(message.arguments["urls"] == .array(urls.map(JSONValue.string)))
    #expect(message.arguments["background"] == .bool(true))

    let response: JSONValue = .object([
        "opened": .number(2),
        "failed": .number(0),
        "background": .bool(true)
    ])
    fixture.channel?.send(.init(id: message.id, kind: "response", command: message.command, result: response))
    #expect(try await request.value == response)
}

@Test @MainActor func browserBridgeActivityStopCancelsThePendingRequestAndSendsCancelFrame() async throws {
    let fixture = BridgeServiceFixture()
    defer { fixture.close() }
    try await fixture.connect()
    let request = Task { try await fixture.service.request("browser.open", arguments: ["url": .string("https://example.com"), "active": .bool(false)]) }
    try await fixture.wait { fixture.messages.count == 1 }
    let task = try #require(fixture.registry.activeTasks.first)
    fixture.registry.cancel(task.id)
    do { _ = try await request.value; Issue.record("Cancelled request unexpectedly succeeded") }
    catch { #expect(error is CancellationError) }
    try await fixture.wait { fixture.messages.contains { $0.kind == "cancel" } }
    #expect(fixture.registry.task(id: task.id)?.state == .cancelled)
    #expect(fixture.messages.last?.id == fixture.messages.first?.id)
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
    let request = Task { try await fixture.service.request("browser.tabs") }
    try await fixture.wait { fixture.messages.count == 1 }
    fixture.service.enabled = false
    do { _ = try await request.value; Issue.record("Disabled bridge unexpectedly returned data") }
    catch { #expect(error is BrowserBridgeError) }
    #expect(fixture.registry.activeTasks.isEmpty)
    #expect(fixture.registry.recentTasks.first?.state == .failed)
    #expect(fixture.service.sessions.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("socket").path))
}
