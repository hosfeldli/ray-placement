import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import RayPlacement

@Test func interruptedResponseRepairIsNarrowAndRequiresAContinuation() throws {
    func rejected(_ status: Int, _ error: [String: Any], previous: Bool = true) throws -> Bool {
        AIResponseContinuationRecovery.shouldRebuild(status: status,
            data: try JSONSerialization.data(withJSONObject: ["error": error]), hasPreviousResponse: previous)
    }
    #expect(try rejected(400, ["param": "previous_response_id", "message": "Unavailable"]))
    #expect(try rejected(404, ["code": "response_not_found"]))
    #expect(try rejected(400, ["message": "No tool output found for function call call_123"]))
    #expect(try !rejected(400, ["param": "tools", "message": "Invalid tool schema"]))
    #expect(try !rejected(400, ["param": "reasoning.effort", "message": "Unsupported value"]))
    #expect(try !rejected(429, ["param": "previous_response_id"]))
    #expect(try !rejected(400, ["param": "previous_response_id"], previous: false))
}

@Test func reservationFormValidatesIndividualFieldsAndRoundTrips() throws {
    let raw = #"{"kind":"form","question":"Complete your reservation details","fields":[{"id":"date","label":"Date","type":"date","required":true,"value":"2026-11-02"},{"id":"time","label":"Time","type":"time","required":true},{"id":"guests","label":"Party size","type":"number","required":true},{"id":"email","label":"Confirmation email","type":"email","required":true},{"id":"area","label":"Seating","type":"select","required":false,"options":["Indoor","Outdoor"]}]}"#
    let question = try #require(AIUserQuestionTools.parse(raw, runID: UUID()))
    var values = ["date": "2026-11-02", "time": "19:00", "guests": "2", "email": "guest@example.com"]
    func response() -> AIUserQuestionResponse {
        .init(questionID: question.id, selectedOptionIDs: [], text: nil, fieldValues: values)
    }
    #expect(response().isValid(for: question))
    #expect((response().toolPayload["field_values"] as? [String: String]) == values)
    values["date"] = "2026-02-31"; #expect(!response().isValid(for: question))
    values["date"] = "2026-11-02"; values["time"] = "25:80"; #expect(!response().isValid(for: question))
    values["time"] = "19:00"; values["email"] = "invalid"; #expect(!response().isValid(for: question))
    let restored = try JSONDecoder().decode(AIUserQuestion.self, from: JSONEncoder().encode(question))
    #expect(restored == question)
    #expect(AIUserQuestionTools.parse(raw.replacingOccurrences(of: "Confirmation email", with: "Password"), runID: UUID()) == nil)
    #expect(AIUserQuestionTools.parse(#"{"kind":"form","question":"Details","fields":[]}"#, runID: UUID()) == nil)
}

@Test @MainActor func reportsEscapeUntrustedContentAndStayOwnedByTheirChat() throws {
    let owner = UUID(), other = UUID()
    let report = AIWorkspaceReportStore.shared.create(conversationID: owner,
        title: "<script>bad()</script>", summary: "Reservation options", sections: [.init(heading: "Options", body: "<iframe src='https://example.com'></iframe>")])
    #expect(report.html.contains("&lt;script&gt;"))
    #expect(!report.html.contains("<script>"))
    #expect(report.html.contains("default-src 'none'"))
    #expect(AIWorkspaceReportStore.shared.reports(for: other).isEmpty)
    #expect(AIWorkspaceReportStore.shared.reports(for: owner).contains(where: { $0.id == report.id }))
    for index in 0..<9 {
        _ = AIWorkspaceReportStore.shared.create(conversationID: owner, title: "Report \(index)", summary: "", sections: [])
    }
    #expect(AIWorkspaceReportStore.shared.reports(for: owner).count == 8)
    #expect(!AIWorkspaceReportStore.shared.reports(for: owner).contains(where: { $0.id == report.id }))
}

@Test @MainActor func settingsNativeWindowCanOpenCloseAndReopenWithoutResizeFeedback() async throws {
    _ = NSApplication.shared
    let launcher = LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false)
    let controller = SettingsWindowController(settings: .shared, viewModel: launcher,
        aiChatModel: AIChatVisualFixtures.model(for: .empty), updateService: UpdateService(),
        reloadExtensions: {}, openGrammarDebugger: {}, extensionStoreModel: ExtensionStoreModel(onInstalled: {}))
    let window = try #require(controller.window)
    for _ in 0..<3 {
        controller.showWindow(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.contentLayoutRect.width >= 900)
        #expect(window.contentLayoutRect.height >= 620)
        window.close()
        await Task.yield()
    }
}

@Test @MainActor func assistantShelfHidesOnlyAIWorkWhileChatIsVisible() {
    let registry = TaskRegistry(recordingRecoveryState: false)
    registry.begin(kind: .aiGeneration, title: "Working on a reservation")
    #expect(ActivityShelfTaskSlots(registry.activeTasks).count == 1)
    #expect(ActivityShelfTaskSlots(registry.activeTasks, assistantVisible: true).count == 0)
    registry.begin(kind: .grammar, title: "Checking writing")
    #expect(ActivityShelfTaskSlots(registry.activeTasks, assistantVisible: true).grammar != nil)
    #expect(ActivityShelfTaskSlots(registry.activeTasks, assistantVisible: true).primary == nil)
}

@Test @MainActor func terminalNamedKeysOperateTheRealPTYAndRejectUnknownKeys() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lima-key-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = AIWorkspaceTerminalCoordinator(testRoot: root)
    let session = try runtime.start(conversationID: UUID(), interactive: true)
    defer { try? runtime.close(sessionID: session.id) }
    _ = try runtime.write(sessionID: session.id, input: "printf 'KEY-CHECK-OK\\n'")
    let accepted = try runtime.sendKey(sessionID: session.id, key: "enter")
    #expect(accepted["input_accepted"] as? Bool == true)
    #expect(accepted["verified_success"] as? Bool == false)
    var output = ""
    for _ in 0..<40 {
        let state = try runtime.status(sessionID: session.id)
        output = state.output
        if output.contains("KEY-CHECK-OK\r\n") || output.contains("KEY-CHECK-OK\n") { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(output.contains("KEY-CHECK-OK\r\n") || output.contains("KEY-CHECK-OK\n"))
    #expect(throws: AIWorkspaceTerminalCoordinator.WorkspaceError.self) {
        try runtime.sendKey(sessionID: session.id, key: "arbitrary_escape_sequence")
    }
}

private final class RecoveryHTTPFixture: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, data) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func interruptedResponseActuallyRebuildsOnceWithoutReplayingTools() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecoveryHTTPFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel(); RecoveryHTTPFixture.handler = nil }
    let client = AIChatResponsesClient(session: session)
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [[String: Any]] = []
        func record(_ request: URLRequest) -> Int {
            lock.lock(); defer { lock.unlock() }
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count))
                }
                data = result
            }
            requests.append((data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:])
            return requests.count
        }
    }
    for scenario in ["recover", "bounded", "unrelated"] {
        let state = State()
        RecoveryHTTPFixture.handler = { request in
            let index = state.record(request)
            if scenario == "recover", index == 2 {
                let sse = "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_fresh\"}}\n\nevent: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Recovered\"}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fresh\",\"status\":\"completed\",\"output\":[]}}\n\n"
                return (200, Data(sse.utf8))
            }
            let parameter = scenario == "unrelated" ? "tools" : "previous_response_id"
            return (400, Data("{\"error\":{\"param\":\"\(parameter)\",\"message\":\"Invalid request\"}}".utf8))
        }
        var text = "", failures = 0
        for try await event in client.streamReply(apiKey: "fixture-not-a-secret", model: "gpt-5",
            input: "Continue", history: [.init(role: .assistant, text: "Earlier answer"), .init(role: .user, text: "Continue")],
            previousResponseID: "resp_interrupted", reasoningEffort: .none, attachments: [], localTools: [], systemInstructions: "Fixture") {
            switch event {
            case .textDelta(let delta): text += delta
            case .failed: failures += 1
            default: break
            }
        }
        #expect(state.requests.count == (scenario == "unrelated" ? 1 : 2))
        #expect(state.requests[0]["previous_response_id"] as? String == "resp_interrupted")
        if state.requests.count == 2 {
            #expect(state.requests[1]["previous_response_id"] == nil)
            let serialized = String(data: try JSONSerialization.data(withJSONObject: state.requests[1]["input"]!), encoding: .utf8)!
            #expect(serialized.contains("Earlier answer") && serialized.contains("Continue"))
            #expect(!serialized.contains("function_call_output"))
        }
        #expect(text == (scenario == "recover" ? "Recovered" : ""))
        #expect(failures == (scenario == "recover" ? 0 : 1))
    }
}

@Test @MainActor func searchSettingsHandoffOpensTheRetainedSettingsWindow() async throws {
    _ = NSApplication.shared
    let controller = LauncherController(updateService: UpdateService())
    defer { controller.hide(); controller.shutdown() }
    controller.showCommandSearch(query: "settings")
    controller.showSettings()
    try await Task.sleep(for: .milliseconds(250))
    let window = try #require(NSApp.windows.first(where: { $0.title == "Lima Settings" && $0.isVisible }))
    #expect(window.contentLayoutRect.width >= 900)
    window.close()
}

@Test @MainActor func temporaryReportOpensAnActualScriptFreeWebPage() async throws {
    _ = NSApplication.shared
    let store = AIWorkspaceReportStore()
    let report = store.create(conversationID: UUID(), title: "Reservation report \(UUID().uuidString.prefix(6))",
        summary: "Two options for dinner, with the next steps in one place.", sections: [
            .init(heading: "Preferred option", body: "Dinner for two · November 2 at 7:00 PM\nAvailability has not yet been checked."),
            .init(heading: "Next steps", body: "Check current availability, review any terms, and confirm the requested details.")])
    store.open(report)
    let window = try #require(NSApp.windows.first(where: { $0.title == report.title }))
    defer { window.close() }
    let web = try #require(window.contentView as? WKWebView)
    #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    #expect(!web.configuration.websiteDataStore.isPersistent)
    for _ in 0..<60 {
        if !web.isLoading { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(100))
    let image = try await web.takeSnapshot(configuration: nil)
    #expect(image.size.width >= 400)
    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("lima-workspace-report-preview.png"))
    }
}
