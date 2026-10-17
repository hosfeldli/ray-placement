import Foundation

struct CodexAppServerStatus: Sendable {
    let connected: Bool
    let threadActive: Bool
    let continuationCount: Int
    let lastError: String?
    let startupMilliseconds: Int?
    let firstEventMilliseconds: Int?
    let firstTextMilliseconds: Int?
}

/// Persistent Codex app-server bridge. Unlike codex exec, a tool result replies
/// to the outstanding JSON-RPC request in the *same* Codex turn and process.
final class CodexAppServerClient: AIProviderClient, @unchecked Sendable {
    static let shared = CodexAppServerClient()
    private let session: Session

    init(executableURL: URL? = nil) {
        session = Session(executableURL: executableURL)
    }

    func shutdown() async { await session.shutdown() }

    func listModels(apiKey: String) async throws -> [AIModelOption] {
        try await CLIChatProviderClient(provider: .codexCLI).listModels(apiKey: apiKey)
    }

    func streamReply(
        apiKey: String, model: String, input: String, history: [AIProviderMessage],
        previousResponseID: String?, reasoningEffort: AIReasoningEffort,
        attachments: [AIAttachment], localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await session.startTurn(
                    model: model, input: input, history: history,
                    previousThreadID: previousResponseID, effort: reasoningEffort,
                    attachments: attachments, tools: localTools,
                    instructions: systemInstructions, stream: continuation
                )
            }
            continuation.onTermination = { @Sendable termination in
                task.cancel()
                if case .cancelled = termination {
                    Task { await self.session.interruptActiveTurn() }
                }
            }
        }
    }

    func streamToolOutputs(
        apiKey: String, model: String, previousResponseID: String,
        history: [AIProviderMessage], outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort, localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await session.resumeToolCalls(outputs: outputs, stream: continuation) }
            continuation.onTermination = { @Sendable termination in
                task.cancel()
                if case .cancelled = termination {
                    Task { await self.session.interruptActiveTurn() }
                }
            }
        }
    }

    /// Safe, metadata-only provider bridge state for diagnostics.
    func status() async -> CodexAppServerStatus {
        await session.status()
    }

    private actor Session {
        private let executableURL: URL?

        init(executableURL: URL?) { self.executableURL = executableURL }

        private struct PendingTool {
            let rpcID: Any
            let threadID: String
        }

        private var process: Process?
        private var generation = 0
        private var stdin: FileHandle?
        private var workingDirectory: URL?
        private var nextRequestID = 1
        private var requests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
        private var knownThreads: [String: String] = [:] // thread ID -> catalog fingerprint
        private var activeThreadID: String?
        private var activeTurnID: String?
        private var currentStream: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation?
        private var bufferedEvents: [AIChatStreamEvent] = []
        private var pendingTools: [String: PendingTool] = [:]
        private var segmentFlushScheduled = false
        private var continuationCount = 0
        private var lastError: String?
        private var sentText = false
        private var streamedReasoningSummaryItemIDs = Set<String>()
        private var lastTurnStartedAt: Date?
        private var startupMilliseconds: Int?
        private var firstEventMilliseconds: Int?
        private var firstTextMilliseconds: Int?

        func status() -> CodexAppServerStatus {
            CodexAppServerStatus(
                connected: process?.isRunning == true, threadActive: activeTurnID != nil,
                continuationCount: continuationCount, lastError: lastError,
                startupMilliseconds: startupMilliseconds,
                firstEventMilliseconds: firstEventMilliseconds,
                firstTextMilliseconds: firstTextMilliseconds
            )
        }

        private func millisecondsSinceTurnStart() -> Int? {
            lastTurnStartedAt.map { max(0, Int(Date().timeIntervalSince($0) * 1_000)) }
        }

        private func markFirstEvent() {
            if firstEventMilliseconds == nil { firstEventMilliseconds = millisecondsSinceTurnStart() }
        }

        private func markFirstText() {
            if firstTextMilliseconds == nil { firstTextMilliseconds = millisecondsSinceTurnStart() }
        }

        private func send(_ value: [String: Any]) throws {
            guard let stdin else { throw BridgeError.disconnected }
            var data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            data.append(0x0A)
            try stdin.write(contentsOf: data)
        }

        private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let id = nextRequestID
            nextRequestID += 1
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    requests[id] = continuation
                    do {
                        try send(["id": id, "method": method, "params": params])
                    } catch {
                        requests.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            } onCancel: {
                Task { await self.cancelRequest(id) }
            }
        }

        private func cancelRequest(_ id: Int) {
            requests.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }

        private func launchIfNeeded() async throws {
            if process?.isRunning == true { return }
            guard let executable = executableURL ?? CLIChatProviderClient.executableURL(for: .codexCLI) else {
                throw BridgeError.missingCodex
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lima-app-server-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = executable
            p.arguments = ["app-server", "--stdio"]
            p.currentDirectoryURL = directory
            workingDirectory = directory
            let input = Pipe()
            let output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            try p.run()
            process = p
            generation &+= 1
            let launchedGeneration = generation
            stdin = input.fileHandleForWriting
            knownThreads.removeAll()
            let reader = output.fileHandleForReading
            Task.detached(priority: .userInitiated) { [weak self] in
                var bytes = Data()
                while !Task.isCancelled {
                    let chunk = reader.availableData
                    guard !chunk.isEmpty else { break }
                    bytes.append(chunk)
                    while let newline = bytes.firstIndex(of: 0x0A) {
                        let line = Data(bytes[..<newline])
                        bytes.removeSubrange(...newline)
                        await self?.receive(line, generation: launchedGeneration)
                    }
                    if bytes.count > 8_000_000 { break }
                }
                await self?.disconnected(generation: launchedGeneration)
            }
            _ = try await request("initialize", [
                "clientInfo": ["name": "Lima", "title": "Lima",
                               "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"],
                "capabilities": ["experimentalApi": true]
            ])
            try send(["method": "initialized"])
        }

        private func receive(_ line: Data, generation receivedGeneration: Int) {
            guard receivedGeneration == generation,
                  let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let method = value["method"] as? String {
                let params = value["params"] as? [String: Any] ?? [:]
                if method == "item/tool/call", let id = value["id"] {
                    handleToolRequest(id: id, params: params)
                } else {
                    handleNotification(method: method, params: params)
                }
                return
            }
            if let id = value["id"] as? Int, let continuation = requests.removeValue(forKey: id) {
                if let error = value["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Codex app-server request failed."
                    continuation.resume(throwing: BridgeError.server(message))
                } else {
                    continuation.resume(returning: value["result"] as? [String: Any] ?? [:])
                }
            }
        }

        func shutdown() {
            generation &+= 1 // Ignore late bytes and EOF from this process after a restart.
            if let process, process.isRunning { process.terminate() }
            try? stdin?.close()
            disconnected(intentional: true)
        }

        private func disconnected(generation expected: Int? = nil, intentional: Bool = false) {
            guard expected == nil || expected == generation else { return }
            let error = BridgeError.disconnected
            for continuation in requests.values { continuation.resume(throwing: error) }
            requests.removeAll()
            currentStream?.finish(throwing: error)
            currentStream = nil
            process = nil
            stdin = nil
            activeTurnID = nil
            pendingTools.removeAll()
            streamedReasoningSummaryItemIDs.removeAll()
            knownThreads.removeAll()
            if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
            workingDirectory = nil
            lastError = intentional ? nil : error.localizedDescription
        }

        private func emit(_ event: AIChatStreamEvent) {
            if let currentStream { currentStream.yield(event) }
            else { bufferedEvents.append(event) }
        }

        private func install(_ stream: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation) {
            let hasBufferedToolCall = bufferedEvents.contains { event in
                if case .outputItem = event { return true }
                return false
            }
            currentStream = stream
            for event in bufferedEvents { stream.yield(event) }
            bufferedEvents.removeAll()
            if hasBufferedToolCall { scheduleSegmentFinish() }
        }

        private func scheduleSegmentFinish() {
            guard currentStream != nil, !segmentFlushScheduled else { return }
            segmentFlushScheduled = true
            Task {
                try? await Task.sleep(for: .milliseconds(35))
                self.finishSegment()
            }
        }

        private func finishSegment() {
            guard let stream = currentStream else {
                segmentFlushScheduled = false
                return
            }
            stream.yield(.completed(activeThreadID))
            stream.finish()
            currentStream = nil
            segmentFlushScheduled = false
        }

        private func handleToolRequest(id: Any, params: [String: Any]) {
            markFirstEvent()
            guard let threadID = params["threadId"] as? String,
                  threadID == activeThreadID,
                  let name = params["tool"] as? String,
                  let callID = params["callId"] as? String,
                  let arguments = params["arguments"],
                  JSONSerialization.isValidJSONObject(arguments),
                  let data = try? JSONSerialization.data(withJSONObject: arguments),
                  data.count <= 32_000,
                  let argumentText = String(data: data, encoding: .utf8) else {
                try? send(["id": id, "result": [
                    "contentItems": [["type": "inputText", "text": #"{"error":"Invalid or unavailable Lima tool request."}"#]],
                    "success": false
                ]])
                return
            }
            pendingTools[callID] = PendingTool(rpcID: id, threadID: threadID)
            let item = AIOutputItem(
                phase: .completed, apiType: "function_call", id: callID,
                callID: callID, name: name, arguments: argumentText
            )
            emit(.outputItem(item))
            // The provider may issue several requests in one turn. Collect
            // adjacent calls before yielding control to Lima's bounded tool loop.
            scheduleSegmentFinish()
        }

        private func handleNotification(method: String, params: [String: Any]) {
            if let threadID = params["threadId"] as? String, threadID != activeThreadID { return }
            markFirstEvent()
            switch method {
            case "item/reasoning/summaryTextDelta":
                // Forward only provider-supplied summary deltas. Raw reasoning
                // text notifications are intentionally not exposed as a summary.
                if let delta = params["delta"] as? String, !delta.isEmpty {
                    if let itemID = params["itemId"] as? String {
                        streamedReasoningSummaryItemIDs.insert(itemID)
                    }
                    emit(.reasoningSummaryDelta(delta))
                }
            case "item/agentMessage/delta":
                if let delta = params["delta"] as? String, !delta.isEmpty {
                    sentText = true
                    markFirstText()
                    emit(.textDelta(delta))
                }
            case "item/completed":
                guard let item = params["item"] as? [String: Any] else { break }
                if item["type"] as? String == "reasoning",
                   let itemID = item["id"] as? String,
                   !streamedReasoningSummaryItemIDs.contains(itemID),
                   let parts = item["summary"] as? [String] {
                    let summary = parts.joined(separator: "\n\n")
                    if !summary.isEmpty { emit(.reasoningSummaryDelta(summary)) }
                } else if !sentText, item["type"] as? String == "agentMessage",
                          let text = item["text"] as? String, !text.isEmpty {
                    sentText = true
                    markFirstText()
                    emit(.textDelta(text))
                }
            case "turn/completed":
                let turn = params["turn"] as? [String: Any] ?? [:]
                if let status = turn["status"] as? String, status == "failed" || status == "interrupted" {
                    lastError = "Codex turn \(status)."
                    emit(.failed(lastError!))
                } else {
                    emit(.completed(activeThreadID))
                }
                currentStream?.finish()
                currentStream = nil
                activeTurnID = nil
                pendingTools.removeAll()
                streamedReasoningSummaryItemIDs.removeAll()
            case "error":
                lastError = params["message"] as? String ?? "Codex app-server error."
                emit(.failed(lastError!))
                currentStream?.finish()
                currentStream = nil
            default:
                break
            }
        }

        private func fingerprint(_ tools: [LimaAIToolDefinition], _ instructions: String) -> String {
            let catalog = tools.map { definition in
                let schema = (try? JSONSerialization.data(withJSONObject: definition.parameters,
                                                         options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "invalid-schema"
                return definition.name + ":" + definition.description + ":" + schema
            }
            return instructions + "\n" + catalog.joined(separator: "\n")
        }

        private func transcript(_ history: [AIProviderMessage], currentInput: String) -> String {
            var earlier = history
            if let last = earlier.last, last.role == .user,
               last.content.contains(where: {
                   if case .text(let text) = $0 { return text == currentInput }
                   return false
               }) {
                earlier.removeLast()
            }
            let prior = earlier.compactMap { message -> String? in
                let texts = message.content.compactMap { content -> String? in
                    if case .text(let text) = content { return text }
                    return nil
                }
                guard !texts.isEmpty else { return nil }
                return "\(message.role == .user ? "User" : "Assistant"): \(texts.joined(separator: "\n"))"
            }.joined(separator: "\n\n")
            return prior.isEmpty ? currentInput : "Previous Lima conversation:\n\(prior)\n\nCurrent user request:\n\(currentInput)"
        }

        func startTurn(
            model: String, input: String, history: [AIProviderMessage],
            previousThreadID: String?, effort: AIReasoningEffort,
            attachments: [AIAttachment], tools: [LimaAIToolDefinition],
            instructions: String,
            stream: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
        ) async {
            do {
                lastTurnStartedAt = Date()
                startupMilliseconds = nil
                firstEventMilliseconds = nil
                firstTextMilliseconds = nil
                try await launchIfNeeded()
                startupMilliseconds = millisecondsSinceTurnStart()
                guard currentStream == nil, activeTurnID == nil else { throw BridgeError.busy }
                lastError = nil
                install(stream)
                sentText = false
                streamedReasoningSummaryItemIDs.removeAll()
                continuationCount = 0
                let catalog = fingerprint(tools, instructions)
                let reused = previousThreadID.flatMap { knownThreads[$0] == catalog ? $0 : nil }
                let threadID: String
                if let reused {
                    threadID = reused
                } else {
                    let dynamicTools: [[String: Any]] = tools.compactMap { definition in
                        guard definition.responsePayload != nil else { return nil }
                        return [
                            "type": "function", "name": definition.name,
                            "description": definition.description,
                            "inputSchema": definition.parameters
                        ]
                    }
                    let result = try await request("thread/start", [
                        "model": model == "default" ? NSNull() : model as Any,
                        "baseInstructions": instructions,
                        "dynamicTools": dynamicTools,
                        "sandbox": "read-only",
                        "approvalPolicy": "never",
                        "cwd": workingDirectory?.path ?? FileManager.default.temporaryDirectory.path,
                        "ephemeral": true
                    ])
                    guard let thread = result["thread"] as? [String: Any],
                          let id = thread["id"] as? String else { throw BridgeError.invalidResponse }
                    knownThreads[id] = catalog
                    threadID = id
                }
                activeThreadID = threadID
                emit(.responseCreated(threadID))
                let prompt = reused == nil ? transcript(history, currentInput: input) : input
                var turnInput: [[String: Any]] = [["type": "text", "text": prompt]]
                for attachment in attachments where attachment.kind == .image {
                    let image = try AIFileAttachmentPolicy.image(for: attachment)
                    turnInput.append(["type": "image", "url": "data:\(image.mediaType);base64,\(image.base64)"])
                }
                let result = try await request("turn/start", [
                    "threadId": threadID, "input": turnInput,
                    "effort": effort.rawValue, "model": model == "default" ? NSNull() : model as Any
                ])
                if currentStream != nil || !pendingTools.isEmpty {
                    activeTurnID = (result["turn"] as? [String: Any])?["id"] as? String
                }
            } catch {
                lastError = error.localizedDescription
                currentStream?.finish(throwing: error)
                currentStream = nil
                activeThreadID = nil
                activeTurnID = nil
            }
        }

        func resumeToolCalls(
            outputs: [[String: Any]],
            stream: AsyncThrowingStream<AIChatStreamEvent, Error>.Continuation
        ) async {
            guard currentStream == nil, activeThreadID != nil else {
                stream.finish(throwing: BridgeError.busy)
                return
            }
            install(stream)
            continuationCount += 1
            for output in outputs {
                guard let callID = output["call_id"] as? String,
                      let pending = pendingTools.removeValue(forKey: callID),
                      pending.threadID == activeThreadID else { continue }
                let text = output["output"] as? String ?? #"{"error":"Missing Lima tool result."}"#
                let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                let state = body?["state"] as? String
                let success = body?["error"] == nil && body?["is_error"] as? Bool != true &&
                    state != "failed" && state != "cancelled"
                var content: [[String: Any]] = [["type": "inputText", "text": text]]
                for image in outputs where image["role"] as? String == "user" {
                    let items = image["content"] as? [[String: Any]] ?? []
                    guard items.contains(where: {
                        $0["type"] as? String == "input_text" &&
                            $0["text"] as? String == "Browser screenshot from tool call \(callID)."
                    }) else { continue }
                    for item in items where item["type"] as? String == "input_image" {
                        if let url = item["image_url"] as? String {
                            content.append(["type": "inputImage", "imageUrl": url])
                        }
                    }
                }
                do {
                    try send(["id": pending.rpcID, "result": [
                        "contentItems": content, "success": success
                    ]])
                } catch {
                    lastError = error.localizedDescription
                    currentStream?.finish(throwing: error)
                    currentStream = nil
                    return
                }
            }
        }

        func interruptActiveTurn() {
            guard let threadID = activeThreadID, let turnID = activeTurnID else { return }
            Task { _ = try? await self.request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) }
        }
    }

    private enum BridgeError: LocalizedError {
        case missingCodex
        case disconnected
        case busy
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingCodex: return "Codex CLI is not installed."
            case .disconnected: return "Codex app-server disconnected."
            case .busy: return "Codex app-server is already handling a turn."
            case .invalidResponse: return "Codex app-server returned an invalid response."
            case .server(let message): return message
            }
        }
    }
}
