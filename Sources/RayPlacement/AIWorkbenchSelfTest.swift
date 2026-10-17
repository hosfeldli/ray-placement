import Foundation
import SwiftUI
import WebKit

/// An opt-in diagnostic run. Native fixtures are isolated from the user's Browser
/// tabs and Terminal sessions; only the provider check sends a bounded request.
@MainActor
final class AIWorkbenchSelfTest: ObservableObject {
    static let shared = AIWorkbenchSelfTest()

    struct Check: Identifiable {
        enum State: String { case passed, failed }
        let id: String
        let title: String
        let state: State
        let detail: String
    }

    @Published private(set) var isRunning = false
    @Published private(set) var checks: [Check] = []
    @Published private(set) var lastRunAt: Date?
    private init() {}

    var passed: Bool { !checks.isEmpty && checks.allSatisfy { $0.state == .passed } }

    func run(provider: AIProvider, model: String, endpoint: String) async {
        guard !isRunning else { return }
        isRunning = true
        checks = []
        lastRunAt = Date()
        defer { isRunning = false }

        await perform("registry", title: "Native tool registry") {
            try await Self.checkRegistry()
        }
        await perform("browser", title: "Native Browser runtime") {
            try await Self.checkBrowser()
        }
        await perform("terminal", title: "Native Terminal runtime") {
            try await Self.checkTerminal()
        }
        await perform("files", title: "Local file fixture") {
            try Self.checkFiles()
        }
        await perform("provider", title: "Provider tool bridge") {
            try await Self.checkProvider(provider: provider, model: model, endpoint: endpoint)
        }
    }

    private func perform(_ id: String, title: String, operation: () async throws -> Void) async {
        do {
            try await operation()
            checks.append(Check(id: id, title: title, state: .passed, detail: "Passed"))
        } catch let error as Failure {
            checks.append(Check(id: id, title: title, state: .failed, detail: error.message))
        } catch {
            // A provider or OS error may contain private paths or server text.
            checks.append(Check(id: id, title: title, state: .failed,
                                detail: "Failed; inspect the local app log for details."))
        }
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func checkRegistry() async throws {
        let definitions = LimaAIToolRegistry.validDefinitions
        let names = Set(definitions.map(\.id))
        for required in ["browser_read", "terminal_start", "lima_capabilities"] {
            guard names.contains(required) else { throw Failure("\(required) is not registered.") }
        }
        let store = LimaAIToolStore.shared
        let environment = AIToolRuntime.shared.resolveEnvironment(runID: UUID(), store: store)
        let exposed = Set(environment.exposedToolIDs)
        for required in ["browser_read", "terminal_start", "lima_capabilities"] {
            guard exposed.contains(required) else {
                throw Failure("\(required) is registered but not exposed by the current Tool Access configuration.")
            }
        }
        let call = AIOutputItem(phase: .completed, apiType: "function_call",
                                callID: UUID().uuidString, name: "lima_capabilities", arguments: "{}")
        let direct = await AIToolRuntime.shared.execute(call, in: environment, store: store) {
            AIContextTools.capabilities(
                call, routedTools: environment.exposedTools, accessMode: environment.accessMode
            )
        }
        guard !direct.isError else { throw Failure("The direct capability tool call failed.") }
    }

    static func checkBrowser() async throws {
        let browser = BrowserWorkspaceModel(runtime: BrowserRuntime(), dataStore: .nonPersistent())
        browser.aiControlMode = .fullControl
        let tab = browser.newTab()
        do {
            guard !tab.hasLiveWebView else { throw Failure("A blank Browser tab eagerly created WebKit.") }
            tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            tab.webView.loadHTMLString("""
                <!doctype html><html><body>
                <h1>Lima Browser Test</h1>
                <a href="https://example.com">Example</a>
                <input aria-label="Test field">
                <button type="button" onclick="document.body.dataset.clicked='yes'">Test Button</button>
                </body></html>
                """, baseURL: URL(string: "https://example.com")!)
            var page: BrowserPageSnapshot?
            for _ in 0..<120 {
                if let snapshot = try? await browser.read(tab.id),
                   snapshot.headings.contains("Lima Browser Test"),
                   snapshot.links.contains(where: { $0.label == "Example" }),
                   snapshot.controls.contains(where: { $0.label == "Test field" }),
                   snapshot.controls.contains(where: { $0.label == "Test Button" }) {
                    page = snapshot
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard let initial = page else { throw Failure("The local WebKit fixture was not semantically readable.") }
            guard initial.find("Lima Browser Test").contains(where: { $0.role == "heading" }) else {
                throw Failure("Browser find could not locate the fixture heading.")
            }
            guard let field = initial.controls.first(where: { $0.label == "Test field" }) else {
                throw Failure("Browser could not find the fixture textbox.")
            }
            let typed = try await browser.interact(tab.id, targetID: field.id, action: .type, text: "LIMA_BROWSER_OK")
            guard typed.performed, typed.postActionVerified,
                  (try await tab.webView.evaluateJavaScript("document.querySelector('input').value") as? String) == "LIMA_BROWSER_OK" else {
                throw Failure("Browser type did not verify the fixture value.")
            }
            let refreshed = try await browser.read(tab.id)
            guard let button = refreshed.controls.first(where: { $0.label == "Test Button" }) else {
                throw Failure("Browser could not reread the fixture button.")
            }
            let clicked = try await browser.interact(tab.id, targetID: button.id, action: .click)
            guard clicked.performed,
                  (try await tab.webView.evaluateJavaScript("document.body.dataset.clicked") as? String) == "yes" else {
                throw Failure("Browser click did not change the fixture.")
            }
            let beforeUserChange = try await browser.read(tab.id)
            guard let stale = beforeUserChange.controls.first(where: { $0.label == "Test Button" }) else {
                throw Failure("Browser could not prepare target invalidation.")
            }
            browser.markPageChangedByUser(tab.id)
            guard !browser.pausedTabIDs.contains(tab.id) else {
                throw Failure("Human input unexpectedly paused AI.")
            }
            do {
                _ = try await browser.interact(tab.id, targetID: stale.id, action: .click)
                throw Failure("A stale target was accepted after human input.")
            } catch BrowserRuntimeError.pageChangedByUser {
                // A fresh semantic read must restore access without a manual resume.
            }
            let afterUserChange = try await browser.read(tab.id)
            guard afterUserChange.headings.contains("Lima Browser Test") else {
                throw Failure("Browser could not reread after human input.")
            }
            try await browser.close(tab.id)
        } catch {
            try? await browser.close(tab.id)
            throw error
        }
    }

    static func checkTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("LimaWorkbenchTerminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let terminal = AIWorkspaceTerminalCoordinator(testRoot: root)
        var sessionID: UUID?
        do {
            let session = try terminal.start(interactive: true)
            sessionID = session.id
            _ = try terminal.write(sessionID: session.id, input: "printf 'LIMA_TERMINAL_OK\\n'\n")
            let deadline = Date().addingTimeInterval(10)
            var cursor: Int? = nil
            var output = ""
            func hasMarker(_ text: String) -> Bool {
                text.split(whereSeparator: \.isNewline).contains {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines) == "LIMA_TERMINAL_OK"
                }
            }
            while Date() < deadline && !hasMarker(output) {
                let result = try await terminal.wait(sessionID: session.id, from: cursor, maxWaitSeconds: 2)
                output += result["output"] as? String ?? ""
                cursor = result["next_byte"] as? Int
            }
            guard hasMarker(output) else {
                throw Failure("The isolated PTY did not return its local marker.")
            }
        } catch {
            await cleanupTerminal(terminal, sessionID: sessionID, root: root)
            throw error
        }
        await cleanupTerminal(terminal, sessionID: sessionID, root: root)
    }

    private static func cleanupTerminal(_ terminal: AIWorkspaceTerminalCoordinator,
                                        sessionID: UUID?, root: URL) async {
        if let sessionID {
            if (try? terminal.status(sessionID: sessionID).state) == .running {
                _ = try? terminal.write(sessionID: sessionID, input: "exit\n")
                for _ in 0..<30 {
                    if (try? terminal.status(sessionID: sessionID).state) != .running { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if (try? terminal.status(sessionID: sessionID).state) == .running {
                    _ = try? terminal.terminate(sessionID: sessionID)
                }
                for _ in 0..<30 {
                    if (try? terminal.status(sessionID: sessionID).state) != .running { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try? terminal.close(sessionID: sessionID)
        }
        try? FileManager.default.removeItem(at: root)
    }

    static func checkFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimaWorkbenchFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.txt")
        try Data("LIMA_FILES_OK".utf8).write(to: fixture, options: .atomic)
        guard try String(contentsOf: fixture, encoding: .utf8) == "LIMA_FILES_OK" else {
            throw Failure("The local file fixture could not be read back.")
        }
    }

    static func checkProvider(provider: AIProvider, model: String, endpoint: String) async throws {
        guard !LimaTestEnvironment.isEnabled || LimaTestEnvironment.allowsLiveAI else {
            throw Failure("Live provider checks are disabled in this test environment.")
        }
        let key: String
        if provider.isCLI {
            guard CLIChatProviderClient.executableURL(for: provider) != nil else {
                throw Failure("The selected CLI is not installed.")
            }
            key = ""
        } else if provider == .openAICompatible {
            key = AIProviderCredentialStore.shared.apiKey(for: provider) ?? ""
        } else {
            guard let configured = AIProviderCredentialStore.shared.apiKey(for: provider),
                  !configured.isEmpty else { throw Failure("The selected provider has no saved API key.") }
            key = configured
        }
        let capability = AIContextTools.definitions.first { $0.id == "lima_capabilities" }!
        let client = AIProviderClientRegistry.client(for: provider, openAICompatibleBaseURL: endpoint)
        let first = AIProviderStreamWatchdog.bounded(client.streamReply(
            apiKey: key, model: model, input: "Call lima_capabilities with {} now. Then briefly acknowledge its result.",
            history: [], previousResponseID: nil, reasoningEffort: .low, attachments: [],
            localTools: [capability], systemInstructions: "This is Lima's opt-in Workbench bridge self-test. Call lima_capabilities exactly once with no arguments. Do not call other tools."
        ), after: .seconds(45))
        var call: AIOutputItem?
        var responseID: String?
        for try await event in first {
            switch event {
            case .responseCreated(let id): responseID = id
            case .completed(let id): responseID = id ?? responseID
            case .outputItem(let item) where item.name == "lima_capabilities": call = item
            case .failed: throw Failure("The provider rejected the capability tool request.")
            default: break
            }
        }
        guard let callID = call?.callID, let responseID else {
            throw Failure("The provider did not invoke lima_capabilities through its tool bridge.")
        }
        let store = LimaAIToolStore.shared
        let environment = AIToolRuntime.shared.resolveEnvironment(runID: UUID(), store: store)
        let result = await AIToolRuntime.shared.execute(call!, in: environment, store: store) {
            AIContextTools.capabilities(
                call!, routedTools: [capability], accessMode: environment.accessMode
            )
        }
        guard !result.isError else { throw Failure("The capability tool failed during provider continuation.") }
        let continuation = AIProviderStreamWatchdog.bounded(client.streamToolOutputs(
            apiKey: key, model: model, previousResponseID: responseID, history: [],
            outputs: [["call_id": callID, "output": result.output]],
            reasoningEffort: .low, localTools: [capability],
            systemInstructions: "Finish the Workbench self-test after receiving the Lima tool result."
        ), after: .seconds(45))
        var completed = false
        for try await event in continuation {
            switch event {
            case .completed: completed = true
            case .failed: throw Failure("The provider could not continue after the Lima tool result.")
            default: break
            }
        }
        guard completed else { throw Failure("The provider continuation did not complete.") }
    }
}
