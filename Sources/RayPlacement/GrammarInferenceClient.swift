import Foundation
import RayPlacementWriting

/// Grammar's provider boundary. It accepts only sanitized text and explicit
/// Grammar instructions; AI Chat history, attachments, and Lima tools never
/// enter this request.
struct GrammarToolFreeRequest: Sendable {
    let provider: AIProvider
    let model: String
    let instructions: String
    let input: String
    let outputSchema: Data
    let reasoningEffort: AIReasoningEffort?
}

protocol GrammarToolFreeRuntime: Sendable {
    func infer(_ request: GrammarToolFreeRequest) async throws -> String
}

/// Codex app-server sessions are single-turn. Lease one of five persistent,
/// isolated clients so deterministic candidate ensembles can run in parallel
/// without colliding with AI Chat or spawning a process for every candidate.
actor CodexGrammarPool {
    static let shared = CodexGrammarPool()
    private let clients: [CodexAppServerClient]
    private var available: [Int]
    private var waiters: [(UUID, CheckedContinuation<Int, Never>)] = []

    init(size: Int = 5, executableURL: URL? = nil) {
        let count = max(1, size)
        clients = (0..<count).map { _ in
            CodexAppServerClient(executableURL: executableURL, toolFreeProcess: true)
        }
        available = Array(0..<count)
    }

    func shutdown() async {
        for client in clients { await client.shutdown() }
    }

    private func acquire() async throws -> Int {
        try Task.checkCancellation()
        if !available.isEmpty { return available.removeFirst() }
        let token = UUID()
        let slot = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: -1) }
                else { waiters.append((token, continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(token) }
        }
        guard slot >= 0 else { throw CancellationError() }
        if Task.isCancelled {
            release(slot)
            throw CancellationError()
        }
        return slot
    }

    private func cancelWaiter(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == token }) else { return }
        waiters.remove(at: index).1.resume(returning: -1)
    }

    private func release(_ slot: Int) {
        if waiters.isEmpty { available.append(slot) }
        else { waiters.removeFirst().1.resume(returning: slot) }
    }

    func infer(_ request: GrammarToolFreeRequest) async throws -> String {
        guard let schema = try JSONSerialization.jsonObject(with: request.outputSchema) as? [String: Any] else {
            throw StealthGrammarRemoteClient.ClientError.invalidConfiguration
        }
        let slot = try await acquire()
        defer { release(slot) }
        try Task.checkCancellation()
        do {
            return try await clients[slot].inferToolFree(
                model: request.model, input: request.input,
                instructions: request.instructions, outputSchema: schema,
                effort: request.reasoningEffort ?? .low
            )
        } catch {
            // A cancelled or failed turn may still be unwinding inside the app-server.
            // Reset that one lane before another candidate leases it; successful lanes
            // keep their persistent processes and avoid per-candidate cold starts.
            await clients[slot].shutdown()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

actor DefaultGrammarToolFreeRuntime: GrammarToolFreeRuntime {
    static let shared = DefaultGrammarToolFreeRuntime()
    private let codexPool: CodexGrammarPool

    init(codexPool: CodexGrammarPool = .shared) {
        self.codexPool = codexPool
    }

    func infer(_ request: GrammarToolFreeRequest) async throws -> String {
        switch request.provider {
        case .codexCLI:
            return try await codexPool.infer(request)
        case .claudeCLI:
            return try await CLIChatProviderClient.inferToolFree(
                provider: request.provider, model: request.model,
                input: request.input, instructions: request.instructions
            )
        default:
            throw StealthGrammarRemoteClient.ClientError.invalidConfiguration
        }
    }
}

@MainActor
final class GrammarInferenceClient {
    private let remote: StealthGrammarRemoteClient
    private let runtime: any GrammarToolFreeRuntime

    init(
        remote: StealthGrammarRemoteClient = StealthGrammarRemoteClient(),
        runtime: any GrammarToolFreeRuntime = DefaultGrammarToolFreeRuntime.shared
    ) {
        self.remote = remote
        self.runtime = runtime
    }

    func models(configuration: DeveloperGrammarConfiguration) async throws -> [DeveloperGrammarModelOption] {
        if configuration.provider.isCLI {
            let options = try await AIProviderClientRegistry.client(
                for: configuration.provider, openAICompatibleBaseURL: ""
            ).listModels(apiKey: "")
            AIModelCatalogStore.shared.replace(options, for: configuration.provider)
            return options.map { .init(id: $0.id, title: $0.displayName) }
        }
        return try await remote.fetchModelsAsync(configuration: configuration)
    }

    func testConnection(configuration: DeveloperGrammarConfiguration) async throws {
        if configuration.provider.isCLI {
            if configuration.provider == .codexCLI {
                let reply = try await rawCLI(
                    configuration: configuration,
                    instructions: "Return exactly a JSON object with an empty changes array. Do not use tools.",
                    input: "Connection check. Return {\"changes\":[]}.",
                    schema: Self.documentSchema
                )
                _ = try StealthGrammarRemoteClient.extractDocumentChanges(from: reply)
            } else {
                let reply = try await rawCLI(
                    configuration: configuration,
                    instructions: StealthGrammarRemoteClient.connectionSystemPrompt,
                    input: "Connection check: reply OK.",
                    schema: Self.textSchema
                )
                guard reply.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                    throw StealthGrammarRemoteClient.ClientError.invalidResponse
                }
            }
            AIModelCatalogStore.shared.markCLIVerified(configuration.model, for: configuration.provider)
            return
        }
        _ = try await remote.testConnectionAsync(configuration: configuration)
    }

    func correctDocument(
        _ contextText: String, configuration: DeveloperGrammarConfiguration,
        systemPrompt: String, temperature: Double?, reasoningEffort: String?
    ) async throws -> [StealthGrammarDocumentChange] {
        if configuration.provider.isCLI {
            let prompt = systemPrompt + "\nReturn only the required JSON object. Do not invoke tools."
            let reply = try await rawCLI(
                configuration: configuration, instructions: prompt,
                input: contextText, schema: Self.documentSchema,
                reasoningEffort: reasoningEffort
            )
            return try StealthGrammarRemoteClient.extractDocumentChanges(from: reply)
        }
        return try await remote.correctDocument(
            contextText, configuration: configuration, systemPrompt: systemPrompt,
            temperature: temperature, reasoningEffort: reasoningEffort
        )
    }

    func correctText(
        _ text: String, configuration: DeveloperGrammarConfiguration,
        systemPrompt: String = StealthGrammarRemoteClient.simpleCorrectionSystemPrompt
    ) async throws -> String {
        if configuration.provider.isCLI {
            let reply = try await rawCLI(
                configuration: configuration,
                instructions: systemPrompt + "\nReturn only JSON with a corrected_text string. Do not invoke tools.",
                input: text, schema: Self.textSchema
            )
            guard let data = reply.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let corrected = object["corrected_text"] as? String else {
                throw StealthGrammarRemoteClient.ClientError.invalidJSON
            }
            return corrected
        }
        return try await remote.correctText(text, configuration: configuration, systemPrompt: systemPrompt)
    }

    func judgeDocument(
        contextText: String, candidateSummary: String,
        configuration: DeveloperGrammarConfiguration,
        profile: GrammarCandidateProfile = .conservativeAdjudicator
    ) async throws -> [StealthGrammarRemoteClient.JudgeDecision] {
        if configuration.provider.isCLI {
            let instructions = """
            You are a conservative adjudicator for a grammar correction ensemble.
            Evaluate only the proposed atomic corrections in the candidate summary.
            Do not proofread the source yourself. Do not invent or rewrite any edit.
            For each issue, return an existing candidate ID or null when none is
            reliable. Preserve meaning and formatting. Confidence is between 0 and 1.
            Return only the required JSON object. Do not invoke tools.
            Profile: \(profile.id)
            Lima diversity seed: \(profile.diversitySeed)
            Prompt version: \(profile.promptVersion)
            """
            let input = """
            Sanitized source document:
            <source>
            \(contextText)
            </source>
            Proposed candidate corrections:
            <candidates>
            \(candidateSummary)
            </candidates>
            """
            let reply = try await rawCLI(
                configuration: configuration, instructions: instructions,
                input: input, schema: Self.judgeSchema,
                reasoningEffort: profile.reasoningEffort
            )
            return try StealthGrammarRemoteClient.extractJudgeDecisions(from: reply)
        }
        return try await remote.judgeDocument(
            contextText: contextText, candidateSummary: candidateSummary,
            configuration: configuration, profile: profile
        )
    }

    private func rawCLI(
        configuration: DeveloperGrammarConfiguration, instructions: String,
        input: String, schema: [String: Any], reasoningEffort: String? = nil
    ) async throws -> String {
        guard CLIChatProviderClient.isValidModelID(configuration.model),
              !input.isEmpty,
              let schemaData = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else {
            throw StealthGrammarRemoteClient.ClientError.invalidConfiguration
        }
        try Task.checkCancellation()
        return try await runtime.infer(GrammarToolFreeRequest(
            provider: configuration.provider, model: configuration.model,
            instructions: instructions, input: input, outputSchema: schemaData,
            reasoningEffort: reasoningEffort.flatMap(AIReasoningEffort.init(rawValue:))
        ))
    }

    private static var documentSchema: [String: Any] {
        StealthGrammarRemoteClient.openAIStructuredOutputFormat["schema"] as? [String: Any] ?? [:]
    }

    private static var judgeSchema: [String: Any] {
        StealthGrammarRemoteClient.openAIJudgeOutputFormat["schema"] as? [String: Any] ?? [:]
    }

    private static let textSchema: [String: Any] = [
        "type": "object", "properties": ["corrected_text": ["type": "string"]],
        "required": ["corrected_text"], "additionalProperties": false
    ]
}
