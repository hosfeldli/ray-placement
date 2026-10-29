import Foundation
import RayPlacementCore

struct AIExecutionCheckpoint: Codable, Sendable {
    enum ToolOutcome: String, Codable, Sendable {
        case dispatched
        case completed
        case failed
        case notExecuted
        case uncertain
    }

    struct ToolEffect: Codable, Sendable {
        let callID: String
        let toolName: String
        let outcome: ToolOutcome
        let outputReference: AIToolOutputReference?
        /// Private blob with the exact bounded text delivered to the provider.
        /// Tool text is kept out of the checkpoint JSON itself.
        let outputBlobID: UUID?
        let recordedAt: Date
    }

    let runID: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let assistantMessageID: UUID
    let originalObjective: String
    let providerID: String
    let modelID: String
    var phase: AIExecutionRunState
    /// The prior completed response/thread before this attempt began. Retry a
    /// failed no-effect request from this base, not its partial response ID.
    var requestBaseReference: String?
    var providerReference: String?
    var completedTools: [ToolEffect]
    var attemptedTools: [ToolEffect]
    var outstandingWork: String
    var pendingApprovalCallIDs: [String]
    var contextManifest: AIContextManifest?
    var toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot?
    /// Digest of the exact bounded instructions sent at the first request.
    /// No instruction body or credentials are stored in checkpoint metadata.
    var instructionDigest: Data?
    var cooldownUntil: Date?
    var failureEvent: AIProviderFailureEvent?
    var automaticResume: Bool
    /// A recognized reasoning-field incompatibility may omit that option once.
    /// Keep the original selection and the deterministic repair distinct.
    var originalReasoningEffort: AIReasoningEffort?
    var recoveryReasoningEffort: AIReasoningEffort?
    var recoveryFingerprint: String?
    var recoveryAttempts: Int
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case runID, conversationID, userMessageID, assistantMessageID
        case originalObjective, providerID, modelID, phase
        case requestBaseReference, providerReference, completedTools, attemptedTools
        case attemptedTool, outstandingWork, pendingApprovalCallIDs, contextManifest
        case toolConfigurationSnapshot, instructionDigest, cooldownUntil, failureEvent, automaticResume
        case originalReasoningEffort, recoveryReasoningEffort
        case recoveryFingerprint, recoveryAttempts, updatedAt
    }

    init(
        runID: UUID, conversationID: UUID, userMessageID: UUID, assistantMessageID: UUID,
        originalObjective: String, providerID: String, modelID: String,
        phase: AIExecutionRunState, requestBaseReference: String?, providerReference: String?,
        completedTools: [ToolEffect], attemptedTools: [ToolEffect], outstandingWork: String,
        pendingApprovalCallIDs: [String], contextManifest: AIContextManifest?,
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot? = nil,
        instructionDigest: Data? = nil, cooldownUntil: Date?, failureEvent: AIProviderFailureEvent?,
        automaticResume: Bool, originalReasoningEffort: AIReasoningEffort? = nil,
        recoveryReasoningEffort: AIReasoningEffort? = nil,
        recoveryFingerprint: String? = nil, recoveryAttempts: Int = 0, updatedAt: Date
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.originalObjective = originalObjective
        self.providerID = providerID
        self.modelID = modelID
        self.phase = phase
        self.requestBaseReference = requestBaseReference
        self.providerReference = providerReference
        self.completedTools = completedTools
        self.attemptedTools = attemptedTools
        self.outstandingWork = outstandingWork
        self.pendingApprovalCallIDs = pendingApprovalCallIDs
        self.contextManifest = contextManifest
        self.toolConfigurationSnapshot = toolConfigurationSnapshot
        self.instructionDigest = instructionDigest
        self.cooldownUntil = cooldownUntil
        self.failureEvent = failureEvent
        self.automaticResume = automaticResume
        self.originalReasoningEffort = originalReasoningEffort
        self.recoveryReasoningEffort = recoveryReasoningEffort
        self.recoveryFingerprint = recoveryFingerprint
        self.recoveryAttempts = recoveryAttempts
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runID = try values.decode(UUID.self, forKey: .runID)
        conversationID = try values.decode(UUID.self, forKey: .conversationID)
        userMessageID = try values.decode(UUID.self, forKey: .userMessageID)
        assistantMessageID = try values.decode(UUID.self, forKey: .assistantMessageID)
        originalObjective = try values.decode(String.self, forKey: .originalObjective)
        providerID = try values.decode(String.self, forKey: .providerID)
        modelID = try values.decode(String.self, forKey: .modelID)
        phase = try values.decode(AIExecutionRunState.self, forKey: .phase)
        requestBaseReference = try values.decodeIfPresent(String.self, forKey: .requestBaseReference)
        providerReference = try values.decodeIfPresent(String.self, forKey: .providerReference)
        completedTools = try values.decodeIfPresent([ToolEffect].self, forKey: .completedTools) ?? []
        if let current = try values.decodeIfPresent([ToolEffect].self, forKey: .attemptedTools) {
            attemptedTools = current
        } else if let legacy = try values.decodeIfPresent(ToolEffect.self, forKey: .attemptedTool) {
            attemptedTools = [legacy]
        } else {
            attemptedTools = []
        }
        outstandingWork = try values.decode(String.self, forKey: .outstandingWork)
        pendingApprovalCallIDs = try values.decodeIfPresent([String].self, forKey: .pendingApprovalCallIDs) ?? []
        contextManifest = try values.decodeIfPresent(AIContextManifest.self, forKey: .contextManifest)
        toolConfigurationSnapshot = try values.decodeIfPresent(
            AIExecutionToolConfigurationSnapshot.self, forKey: .toolConfigurationSnapshot
        )
        instructionDigest = try values.decodeIfPresent(Data.self, forKey: .instructionDigest)
        cooldownUntil = try values.decodeIfPresent(Date.self, forKey: .cooldownUntil)
        failureEvent = try values.decodeIfPresent(AIProviderFailureEvent.self, forKey: .failureEvent)
        automaticResume = try values.decode(Bool.self, forKey: .automaticResume)
        originalReasoningEffort = try values.decodeIfPresent(AIReasoningEffort.self, forKey: .originalReasoningEffort)
        recoveryReasoningEffort = try values.decodeIfPresent(AIReasoningEffort.self, forKey: .recoveryReasoningEffort)
        recoveryFingerprint = try values.decodeIfPresent(String.self, forKey: .recoveryFingerprint)
        recoveryAttempts = max(0, try values.decodeIfPresent(Int.self, forKey: .recoveryAttempts) ?? 0)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(runID, forKey: .runID)
        try values.encode(conversationID, forKey: .conversationID)
        try values.encode(userMessageID, forKey: .userMessageID)
        try values.encode(assistantMessageID, forKey: .assistantMessageID)
        try values.encode(originalObjective, forKey: .originalObjective)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(modelID, forKey: .modelID)
        try values.encode(phase, forKey: .phase)
        try values.encodeIfPresent(requestBaseReference, forKey: .requestBaseReference)
        try values.encodeIfPresent(providerReference, forKey: .providerReference)
        try values.encode(completedTools, forKey: .completedTools)
        try values.encode(attemptedTools, forKey: .attemptedTools)
        try values.encode(outstandingWork, forKey: .outstandingWork)
        try values.encode(pendingApprovalCallIDs, forKey: .pendingApprovalCallIDs)
        try values.encodeIfPresent(contextManifest, forKey: .contextManifest)
        try values.encodeIfPresent(toolConfigurationSnapshot, forKey: .toolConfigurationSnapshot)
        try values.encodeIfPresent(instructionDigest, forKey: .instructionDigest)
        try values.encodeIfPresent(cooldownUntil, forKey: .cooldownUntil)
        try values.encodeIfPresent(failureEvent, forKey: .failureEvent)
        try values.encode(automaticResume, forKey: .automaticResume)
        try values.encodeIfPresent(originalReasoningEffort, forKey: .originalReasoningEffort)
        try values.encodeIfPresent(recoveryReasoningEffort, forKey: .recoveryReasoningEffort)
        try values.encodeIfPresent(recoveryFingerprint, forKey: .recoveryFingerprint)
        try values.encode(recoveryAttempts, forKey: .recoveryAttempts)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    var mayHaveConsequentialEffects: Bool {
        !attemptedTools.isEmpty || !completedTools.isEmpty
    }
}

/// Durable, private, atomic snapshots at execution boundaries. A corrupt file
/// is never interpreted as an empty task list.
actor AIExecutionCheckpointStore {
    static let shared = AIExecutionCheckpointStore()

    enum StoreError: Error {
        case unavailable
    }

    private let url: URL
    private let fileStore = PrivateFileStore()
    private let outputDirectory: URL
    private var checkpoints: [UUID: AIExecutionCheckpoint]
    private var loadFailed = false

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let testURL = LimaTestEnvironment.storageURL(relativePath: "AI/execution-checkpoints.json") {
            self.url = testURL
        } else {
            self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lima/AI/execution-checkpoints.json")
        }
        outputDirectory = self.url.deletingLastPathComponent()
            .appendingPathComponent("execution-tool-results", isDirectory: true)
        let result = fileStore.loadJSON([UUID: AIExecutionCheckpoint].self, from: self.url)
        switch result.result.state {
        case .missing:
            checkpoints = [:]
        case .loaded:
            checkpoints = result.value ?? [:]
            loadFailed = result.value == nil
        case .corrupt, .unreadable:
            checkpoints = [:]
            loadFailed = true
        }
    }

    func all() throws -> [AIExecutionCheckpoint] {
        guard !loadFailed else { throw StoreError.unavailable }
        return checkpoints.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func checkpoint(runID: UUID) throws -> AIExecutionCheckpoint? {
        guard !loadFailed else { throw StoreError.unavailable }
        return checkpoints[runID]
    }

    func upsert(_ checkpoint: AIExecutionCheckpoint) throws {
        guard !loadFailed else { throw StoreError.unavailable }
        var next = checkpoints
        next[checkpoint.runID] = checkpoint
        try fileStore.write(next, to: url, backupExisting: false)
        checkpoints = next
    }

    func update(runID: UUID, _ body: @Sendable (inout AIExecutionCheckpoint) -> Void) throws {
        guard !loadFailed, var checkpoint = checkpoints[runID] else { throw StoreError.unavailable }
        body(&checkpoint)
        checkpoint.updatedAt = Date()
        try upsert(checkpoint)
    }

    func beginTool(runID: UUID, callID: String, toolName: String) throws {
        guard !loadFailed, !callID.isEmpty, callID.utf8.count <= 512,
              !toolName.isEmpty, toolName.utf8.count <= 128,
              var checkpoint = checkpoints[runID],
              !checkpoint.completedTools.contains(where: { $0.callID == callID }),
              !checkpoint.attemptedTools.contains(where: { $0.callID == callID }) else {
            throw StoreError.unavailable
        }
        checkpoint.attemptedTools.append(.init(
            callID: callID, toolName: toolName, outcome: .dispatched,
            outputReference: nil, outputBlobID: nil, recordedAt: Date()
        ))
        checkpoint.phase = .runningTools
        checkpoint.updatedAt = Date()
        try upsert(checkpoint)
    }

    @discardableResult
    func finishTool(runID: UUID, callID: String, output: String,
                    outputReference: AIToolOutputReference? = nil) throws -> AIExecutionCheckpoint.ToolEffect {
        guard !loadFailed, var checkpoint = checkpoints[runID],
              let attempted = checkpoint.attemptedTools.first(where: { $0.callID == callID }),
              !checkpoint.completedTools.contains(where: { $0.callID == callID }) else {
            throw StoreError.unavailable
        }
        let blobID = try saveToolOutput(runID: runID, text: output)
        let body = output.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let state = body?["state"] as? String
        let failed = (body?["error"] != nil && !(body?["error"] is NSNull))
            || body?["is_error"] as? Bool == true
            || state == "failed" || state == "cancelled"
        let completed = AIExecutionCheckpoint.ToolEffect(
            callID: callID, toolName: attempted.toolName,
            outcome: failed ? .failed : .completed,
            outputReference: outputReference, outputBlobID: blobID, recordedAt: Date()
        )
        checkpoint.completedTools.append(completed)
        checkpoint.attemptedTools.removeAll { $0.callID == callID }
        checkpoint.updatedAt = Date()
        do {
            try upsert(checkpoint)
        } catch {
            try? FileManager.default.removeItem(at: outputURL(runID: runID, id: blobID))
            throw error
        }
        return completed
    }

    /// Persist the exact text selected for provider continuation after visual
    /// sanitization. Synthetic denied/skipped results are recorded as not run.
    /// A journaled action keeps its prior outcome; this never turns an
    /// uncertain dispatched action into a completed one.
    func persistProviderOutput(
        runID: UUID, callID: String, toolName: String, text: String
    ) throws {
        guard !loadFailed, var checkpoint = checkpoints[runID],
              !checkpoint.attemptedTools.contains(where: { $0.callID == callID }) else {
            throw StoreError.unavailable
        }
        let blobID = try saveToolOutput(runID: runID, text: text)
        let previousID: UUID?
        if let index = checkpoint.completedTools.firstIndex(where: { $0.callID == callID }) {
            let prior = checkpoint.completedTools[index]
            previousID = prior.outputBlobID
            checkpoint.completedTools[index] = .init(
                callID: callID, toolName: prior.toolName, outcome: prior.outcome,
                outputReference: prior.outputReference, outputBlobID: blobID,
                recordedAt: Date()
            )
        } else {
            previousID = nil
            checkpoint.completedTools.append(.init(
                callID: callID, toolName: toolName, outcome: .notExecuted,
                outputReference: nil, outputBlobID: blobID, recordedAt: Date()
            ))
        }
        checkpoint.updatedAt = Date()
        do {
            try upsert(checkpoint)
        } catch {
            try? FileManager.default.removeItem(at: outputURL(runID: runID, id: blobID))
            throw error
        }
        if let previousID {
            try? FileManager.default.removeItem(at: outputURL(runID: runID, id: previousID))
        }
    }

    /// Save provider-visible text before marking a tool call completed. A crash
    /// between the tool effect and this write leaves the call uncertain.
    func saveToolOutput(runID: UUID, text: String) throws -> UUID {
        guard !loadFailed, checkpoints[runID] != nil,
              text.utf8.count <= 128_000 else { throw StoreError.unavailable }
        let id = UUID()
        try fileStore.write(text, to: outputURL(runID: runID, id: id), backupExisting: false)
        return id
    }

    func toolOutput(runID: UUID, id: UUID) throws -> String {
        guard !loadFailed, checkpoints[runID] != nil else { throw StoreError.unavailable }
        let loaded = fileStore.loadJSON(String.self, from: outputURL(runID: runID, id: id))
        guard loaded.result.state == .loaded, let text = loaded.value,
              text.utf8.count <= 128_000 else { throw StoreError.unavailable }
        return text
    }

    func remove(runID: UUID) throws {
        guard !loadFailed else { throw StoreError.unavailable }
        var next = checkpoints
        let removed = next.removeValue(forKey: runID)
        try fileStore.write(next, to: url, backupExisting: false)
        checkpoints = next
        for effect in (removed?.completedTools ?? []) + (removed?.attemptedTools ?? []) {
            if let id = effect.outputBlobID {
                try? FileManager.default.removeItem(at: outputURL(runID: runID, id: id))
            }
        }
    }

    private func outputURL(runID: UUID, id: UUID) -> URL {
        outputDirectory.appendingPathComponent("\(runID.uuidString)-\(id.uuidString).json")
    }
}
