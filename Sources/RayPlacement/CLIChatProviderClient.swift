import Foundation

/// Uses an existing local CLI login for chat. This adapter does not grant the
/// CLI access to Lima's native tools or MCP servers; those require an API provider.
struct CLIChatProviderClient: AIChatTransport {
    enum Failure: LocalizedError {
        case missingCLI(String)
        case invalidModel
        case unsupportedAttachment
        case emptyResponse
        case commandFailed(String)
        case toolsUnavailable

        var errorDescription: String? {
            switch self {
            case .missingCLI(let name):
                return "\(name) is not installed in a standard CLI location. Install it and sign in locally before selecting this provider."
            case .invalidModel:
                return "The CLI model ID contains unsupported characters. Use a model name without spaces or command options."
            case .unsupportedAttachment:
                return "This CLI provider currently accepts text context only. Remove image or file-only attachments and try again."
            case .emptyResponse:
                return "The CLI finished without a readable reply. Check its local sign-in and model settings."
            case .commandFailed(let name):
                return "\(name) could not complete the request. Check that its CLI is installed, signed in, and supports the selected model."
            case .toolsUnavailable:
                return "Lima browser, Notes, and other native tools are not available through this CLI provider. Choose an API provider for tool-based requests."
            }
        }
    }

    let provider: AIProvider
    private static let maximumOutputBytes = 2 * 1024 * 1024

    static func executableURL(for provider: AIProvider) -> URL? {
        let name: String
        switch provider {
        case .codexCLI: name = "codex"
        case .claudeCLI: name = "claude"
        default: return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let directories = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + pathEntries
        for directory in directories where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func listModels(apiKey: String) async throws -> [AIModelOption] {
        guard Self.executableURL(for: provider) != nil else { throw Failure.missingCLI(provider.title) }
        // Neither CLI exposes a stable, cheap model-catalog command. The CLI
        // default is always available as a selection; users may enter a model ID.
        return provider.chatModels
    }

    func streamReply(
        apiKey: String,
        model: String,
        input: String,
        history: [AIProviderMessage],
        previousResponseID: String?,
        reasoningEffort: AIReasoningEffort,
        attachments: [AIAttachment],
        mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition],
        systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    guard mcpServers.isEmpty && localTools.isEmpty else { throw Failure.toolsUnavailable }
                    let prompt = try Self.prompt(
                        input: input, history: history, attachments: attachments,
                        systemInstructions: systemInstructions
                    )
                    let output = try await Self.run(provider: provider, model: model, prompt: prompt)
                    try Task.checkCancellation()
                    let reply = try Self.extractReply(from: output, provider: provider)
                    continuation.yield(.textDelta(reply))
                    continuation.yield(.completed(nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func streamApproval(
        apiKey: String, model: String, previousResponseID: String,
        requestID: String, approve: Bool, reason: String?,
        reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition], systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: Failure.toolsUnavailable) }
    }

    func streamToolOutputs(
        apiKey: String, model: String, previousResponseID: String,
        history: [AIProviderMessage], outputs: [[String: Any]],
        reasoningEffort: AIReasoningEffort, mcpServers: [MCPServer],
        localTools: [LimaAIToolDefinition], systemInstructions: String
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: Failure.toolsUnavailable) }
    }

    static func prompt(
        input: String, history: [AIProviderMessage],
        attachments: [AIAttachment], systemInstructions: String
    ) throws -> String {
        let header = [
            "You are responding inside Lima. Answer the user's request using only the conversation and context below.",
            "Do not use CLI tools, browse files, run commands, or access local data. Lima native tools are unavailable in this provider mode.",
            "Instructions:\n" + String(systemInstructions.prefix(20_000))
        ]
        var turns: [String] = []
        for message in history {
            let text = message.content.compactMap { content -> String? in
                if case .text(let value) = content { return value }
                return nil
            }.joined(separator: "\n")
            guard !text.isEmpty else { continue }
            turns.append(message.role.rawValue.uppercased() + ":\n" + String(text.prefix(60_000)))
        }
        let latest = "USER:\n" + String(input.prefix(60_000))
        if turns.last != latest { turns.append(latest) }

        var context: [String] = []
        var contextRemaining = 50_000
        for attachment in attachments {
            guard let text = attachment.text, !text.isEmpty else { throw Failure.unsupportedAttachment }
            let label = "VISIBLE CONTEXT — " + String(attachment.displayName.prefix(200)) + ":\n"
            let value = label + String(text.prefix(max(0, contextRemaining - label.count)))
            context.append(value)
            contextRemaining = max(0, contextRemaining - value.count)
        }

        let ending = "Reply to the latest user message. Do not describe unavailable tools as if you used them."
        let fixed = (header + context + [ending]).joined(separator: "\n\n")
        var remaining = max(0, 140_000 - fixed.count - 20)
        var selectedTurns: [String] = []
        // Spend the history budget newest-first. A long old chat must never
        // push the user's current message out of the prompt.
        for turn in turns.reversed() where remaining > 0 {
            let included = String(turn.prefix(remaining))
            selectedTurns.append(included)
            remaining -= included.count + 2
        }
        return (header + Array(selectedTurns.reversed()) + context + [ending]).joined(separator: "\n\n")
    }

    static func arguments(for provider: AIProvider, model: String, workingDirectory: URL) -> [String] {
        let chosenModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .codexCLI:
            var args = [
                "exec", "--json", "--ephemeral", "--ignore-user-config",
                "--sandbox", "read-only", "--skip-git-repo-check",
                "--cd", workingDirectory.path
            ]
            if chosenModel != "default" && !chosenModel.isEmpty { args += ["--model", chosenModel] }
            return args + ["-"]
        case .claudeCLI:
            var args = ["-p", "--output-format", "json", "--tools", ""]
            if chosenModel != "default" && !chosenModel.isEmpty { args += ["--model", chosenModel] }
            return args
        default:
            return []
        }
    }

    static func extractReply(from data: Data, provider: AIProvider) throws -> String {
        if provider == .claudeCLI,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reply = object["result"] as? String,
           !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reply.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var finalReply: String?
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String, !text.isEmpty {
                finalReply = text
            }
            if let result = object["result"] as? String, !result.isEmpty { finalReply = result }
        }
        guard let finalReply, !finalReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyResponse
        }
        return finalReply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(provider: AIProvider, model: String, prompt: String) async throws -> Data {
        guard let executable = executableURL(for: provider) else { throw Failure.missingCLI(provider.title) }
        let allowedModelCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-")
        guard model == "default" || (!model.isEmpty && model.count <= 128 && !model.hasPrefix("-")
            && model.unicodeScalars.allSatisfy({ allowedModelCharacters.contains($0) })) else {
            throw Failure.invalidModel
        }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lima-cli-chat-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: provider, model: model, workingDirectory: directory)
        process.currentDirectoryURL = directory
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withTaskCancellationHandler {
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180, execute: timeout)
            defer { timeout.cancel() }
            let stdoutReader = Task.detached(priority: .utility) {
                readBounded(outputPipe.fileHandleForReading, limit: maximumOutputBytes)
            }
            let stderrReader = Task.detached(priority: .utility) {
                readBounded(errorPipe.fileHandleForReading, limit: 16 * 1024)
            }
            let inputWriter = Task.detached(priority: .utility) {
                try? inputPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? inputPipe.fileHandleForWriting.close()
            }
            let status = await Task.detached(priority: .utility) {
                process.waitUntilExit()
                return process.terminationStatus
            }.value
            _ = await inputWriter.value
            let output = await stdoutReader.value
            _ = await stderrReader.value // Never surface stderr: it can contain prompt content.
            try Task.checkCancellation()
            guard status == 0 else { throw Failure.commandFailed(provider.title) }
            return output
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func readBounded(_ handle: FileHandle, limit: Int) -> Data {
        var result = Data()
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            if result.count < limit { result.append(chunk.prefix(limit - result.count)) }
        }
        return result
    }
}
