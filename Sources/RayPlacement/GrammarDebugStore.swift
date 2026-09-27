import Foundation
import RayPlacementWriting
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct GrammarDebugRun: Identifiable, Codable, Sendable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date?
    let strategy: GrammarEnsembleStrategy
    let judgeUsed: Bool
    let judgeError: String?
    let status: String
    let error: String?
    let candidateCount: Int
    let appliedCount: Int
    let sourceText: String?
    let contextText: String?
    let systemPrompt: String?
    let finalChanges: [StealthGrammarDocumentChange]
    let configurationSnapshot: GrammarRunConfigurationSnapshot?
    let totalLatencyMS: Int
    let provider: String?
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let apiCallCount: Int
    let requestIDs: [String]
    let safetyRejectedCount: Int
    let rejectionReasons: [String: Int]
    let agreementScore: Double?
    init(id: UUID, startedAt: Date, finishedAt: Date?, strategy: GrammarEnsembleStrategy, judgeUsed: Bool, judgeError: String?, status: String, error: String?, candidateCount: Int, appliedCount: Int, sourceText: String?, contextText: String?, systemPrompt: String?, finalChanges: [StealthGrammarDocumentChange], configurationSnapshot: GrammarRunConfigurationSnapshot? = nil, totalLatencyMS: Int = 0, provider: String? = nil, model: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0, apiCallCount: Int = 0, requestIDs: [String] = [], safetyRejectedCount: Int = 0, rejectionReasons: [String: Int] = [:], agreementScore: Double? = nil) {
        self.id = id; self.startedAt = startedAt; self.finishedAt = finishedAt; self.strategy = strategy; self.judgeUsed = judgeUsed; self.judgeError = judgeError; self.status = status; self.error = error; self.candidateCount = candidateCount; self.appliedCount = appliedCount; self.sourceText = sourceText; self.contextText = contextText; self.systemPrompt = systemPrompt; self.finalChanges = finalChanges; self.configurationSnapshot = configurationSnapshot; self.totalLatencyMS = totalLatencyMS; self.provider = provider; self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.apiCallCount = apiCallCount; self.requestIDs = requestIDs; self.safetyRejectedCount = safetyRejectedCount; self.rejectionReasons = rejectionReasons; self.agreementScore = agreementScore
    }

    enum CodingKeys: String, CodingKey { case id, startedAt, finishedAt, strategy, judgeUsed, judgeError, status, error, candidateCount, appliedCount, sourceText, contextText, systemPrompt, finalChanges, configurationSnapshot, totalLatencyMS, provider, model, inputTokens, outputTokens, apiCallCount, requestIDs, safetyRejectedCount, rejectionReasons, agreementScore }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), startedAt: try c.decode(Date.self, forKey: .startedAt), finishedAt: try c.decodeIfPresent(Date.self, forKey: .finishedAt), strategy: try c.decode(GrammarEnsembleStrategy.self, forKey: .strategy), judgeUsed: try c.decode(Bool.self, forKey: .judgeUsed), judgeError: try c.decodeIfPresent(String.self, forKey: .judgeError), status: try c.decode(String.self, forKey: .status), error: try c.decodeIfPresent(String.self, forKey: .error), candidateCount: try c.decode(Int.self, forKey: .candidateCount), appliedCount: try c.decode(Int.self, forKey: .appliedCount), sourceText: try c.decodeIfPresent(String.self, forKey: .sourceText), contextText: try c.decodeIfPresent(String.self, forKey: .contextText), systemPrompt: try c.decodeIfPresent(String.self, forKey: .systemPrompt), finalChanges: try c.decode([StealthGrammarDocumentChange].self, forKey: .finalChanges), configurationSnapshot: try c.decodeIfPresent(GrammarRunConfigurationSnapshot.self, forKey: .configurationSnapshot), totalLatencyMS: try c.decodeIfPresent(Int.self, forKey: .totalLatencyMS) ?? 0, provider: try c.decodeIfPresent(String.self, forKey: .provider), model: try c.decodeIfPresent(String.self, forKey: .model), inputTokens: try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0, outputTokens: try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0, apiCallCount: try c.decodeIfPresent(Int.self, forKey: .apiCallCount) ?? 0, requestIDs: try c.decodeIfPresent([String].self, forKey: .requestIDs) ?? [], safetyRejectedCount: try c.decodeIfPresent(Int.self, forKey: .safetyRejectedCount) ?? 0, rejectionReasons: try c.decodeIfPresent([String: Int].self, forKey: .rejectionReasons) ?? [:], agreementScore: try c.decodeIfPresent(Double.self, forKey: .agreementScore))
    }
}

struct GrammarDebugCandidate: Identifiable, Codable, Sendable {
    let id: String
    let runID: UUID
    let profileID: String
    let seed: UInt64
    let promptVersion: String
    let instructions: String
    let prompt: String
    let temperature: Double?
    let latencyMS: Int
    let rawChanges: [StealthGrammarDocumentChange]
    let acceptedChanges: [StealthGrammarDocumentChange]
    let rejectedCount: Int
    let error: String?
    let inputTokens: Int
    let outputTokens: Int
    let apiCallCount: Int
    let requestID: String?
    let rejectionReasons: [String]
    init(id: String, runID: UUID, profileID: String, seed: UInt64, promptVersion: String, instructions: String, prompt: String, temperature: Double?, latencyMS: Int, rawChanges: [StealthGrammarDocumentChange], acceptedChanges: [StealthGrammarDocumentChange], rejectedCount: Int, error: String?, inputTokens: Int = 0, outputTokens: Int = 0, apiCallCount: Int = 1, requestID: String? = nil, rejectionReasons: [String] = []) {
        self.id = id; self.runID = runID; self.profileID = profileID; self.seed = seed; self.promptVersion = promptVersion
        self.instructions = instructions; self.prompt = prompt; self.temperature = temperature; self.latencyMS = latencyMS
        self.rawChanges = rawChanges; self.acceptedChanges = acceptedChanges; self.rejectedCount = rejectedCount; self.error = error
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.apiCallCount = apiCallCount; self.requestID = requestID; self.rejectionReasons = rejectionReasons
    }
}

struct GrammarDebugFeedback: Codable, Sendable {
    let runID: UUID
    let candidateID: String?
    let decision: String
    let note: String?
    let createdAt: Date
}

struct GrammarRejectionAggregate: Identifiable, Sendable {
    let reason: String
    let count: Int
    public var id: String { reason }
}

struct GrammarDebugRequest: Identifiable, Codable, Sendable {
    let id: String
    let runID: UUID
    let kind: String
    let provider: String?
    let model: String?
    let status: String
    let latencyMS: Int
    let inputTokens: Int
    let outputTokens: Int
    let createdAt: Date
}

struct GrammarSeedAnalytics: Identifiable, Sendable {
    let seed: UInt64
    let profileID: String
    let runCount: Int
    let proposalCount: Int
    let acceptedCount: Int
    let rejectedCount: Int
    let feedbackApprovedCount: Int
    let feedbackRejectedCount: Int
    let averageLatencyMS: Int

    var id: UInt64 { seed }
    var contributionRate: Double { runCount == 0 ? 0 : Double(acceptedCount) / Double(runCount) }
    var rejectionRate: Double {
        let total = acceptedCount + rejectedCount
        return total == 0 ? 0 : Double(rejectedCount) / Double(total)
    }
}

final class GrammarDebugStore: @unchecked Sendable {
    static let shared = GrammarDebugStore()

    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL? = nil) {
        do {
            if databaseURL == nil { try ApplicationPaths.prepare() }
            let url = databaseURL ?? ApplicationPaths.grammarDebugDatabase
            if databaseURL != nil {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw StoreError.openFailed
            }
            try executeScript("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
            try executeScript("""
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY, started_at REAL NOT NULL, finished_at REAL,
                    strategy TEXT NOT NULL, judge_used INTEGER NOT NULL DEFAULT 0,
                    judge_error TEXT, status TEXT NOT NULL, error TEXT,
                    candidate_count INTEGER NOT NULL DEFAULT 0, applied_count INTEGER NOT NULL DEFAULT 0,
                    source_text TEXT, context_text TEXT, system_prompt TEXT, final_changes TEXT NOT NULL DEFAULT '[]', configuration_snapshot TEXT, total_latency_ms INTEGER NOT NULL DEFAULT 0, provider TEXT, model TEXT, input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, api_call_count INTEGER NOT NULL DEFAULT 0, request_ids TEXT NOT NULL DEFAULT '[]', safety_rejected_count INTEGER NOT NULL DEFAULT 0, rejection_reasons TEXT NOT NULL DEFAULT '{}', agreement_score REAL
                );
                CREATE TABLE IF NOT EXISTS candidates (
                    id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    profile_id TEXT NOT NULL, seed INTEGER NOT NULL, prompt_version TEXT NOT NULL,
                    instructions TEXT NOT NULL, prompt TEXT NOT NULL, temperature REAL,
                    latency_ms INTEGER NOT NULL, raw_changes TEXT NOT NULL, accepted_changes TEXT NOT NULL,
                    rejected_count INTEGER NOT NULL DEFAULT 0, error TEXT, input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, api_call_count INTEGER NOT NULL DEFAULT 1, request_id TEXT, rejection_reasons TEXT NOT NULL DEFAULT '[]',
                    PRIMARY KEY(run_id, id)
                );
                CREATE TABLE IF NOT EXISTS feedback (
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    candidate_id TEXT, decision TEXT NOT NULL, note TEXT, created_at REAL NOT NULL,
                    PRIMARY KEY(run_id, candidate_id)
                );
                CREATE INDEX IF NOT EXISTS candidates_seed_idx ON candidates(seed);
                CREATE INDEX IF NOT EXISTS runs_started_idx ON runs(started_at DESC);
                CREATE TABLE IF NOT EXISTS requests (
                    id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, provider TEXT, model TEXT, status TEXT NOT NULL,
                    latency_ms INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL
                );
            """)
            // Existing databases predate configuration snapshots. SQLite has no
            // IF NOT EXISTS form for columns, so tolerate the already-exists
            // error while upgrading older installs in place.
            for column in [
                "configuration_snapshot TEXT", "total_latency_ms INTEGER NOT NULL DEFAULT 0", "provider TEXT",
                "model TEXT", "input_tokens INTEGER NOT NULL DEFAULT 0", "output_tokens INTEGER NOT NULL DEFAULT 0",
                "api_call_count INTEGER NOT NULL DEFAULT 0", "request_ids TEXT NOT NULL DEFAULT '[]'",
                "safety_rejected_count INTEGER NOT NULL DEFAULT 0", "rejection_reasons TEXT NOT NULL DEFAULT '{}'",
                "agreement_score REAL"
            ] { try? execute("ALTER TABLE runs ADD COLUMN \(column);") }
            for column in ["input_tokens INTEGER NOT NULL DEFAULT 0", "output_tokens INTEGER NOT NULL DEFAULT 0", "api_call_count INTEGER NOT NULL DEFAULT 1", "request_id TEXT", "rejection_reasons TEXT NOT NULL DEFAULT '[]'"] {
                try? execute("ALTER TABLE candidates ADD COLUMN \(column);")
            }
        } catch {
            close()
        }
    }

    deinit { close() }

    func beginRun(
        id: UUID,
        startedAt: Date,
        strategy: GrammarEnsembleStrategy,
        sourceText: String?,
        contextText: String?,
        systemPrompt: String?,
        configurationSnapshot: GrammarRunConfigurationSnapshot? = nil,
        provider: String? = nil,
        model: String? = nil
    ) {
        withLock {
            try? execute("INSERT OR REPLACE INTO runs (id, started_at, strategy, status, source_text, context_text, system_prompt, configuration_snapshot, provider, model) VALUES (?, ?, ?, 'running', ?, ?, ?, ?, ?, ?);", bindings: [
                .text(id.uuidString), .double(startedAt.timeIntervalSince1970), .text(strategy.rawValue),
                .nullableText(sourceText), .nullableText(contextText), .nullableText(systemPrompt),
                .nullableText(configurationSnapshot.flatMap { try? encode($0) }), .nullableText(provider), .nullableText(model)
            ])
        }
    }

    func recordCandidate(_ candidate: GrammarDebugCandidate) {
        withLock {
            let raw = (try? encode(candidate.rawChanges)) ?? "[]"
            let accepted = (try? encode(candidate.acceptedChanges)) ?? "[]"
            try? execute("""
                INSERT OR REPLACE INTO candidates
                (id, run_id, profile_id, seed, prompt_version, instructions, prompt, temperature, latency_ms, raw_changes, accepted_changes, rejected_count, error, input_tokens, output_tokens, api_call_count, request_id, rejection_reasons)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, bindings: [
                .text(candidate.id), .text(candidate.runID.uuidString), .text(candidate.profileID), .int64(Int64(candidate.seed)),
                .text(candidate.promptVersion), .text(candidate.instructions), .text(candidate.prompt), .nullableDouble(candidate.temperature),
                .int64(Int64(candidate.latencyMS)), .text(raw), .text(accepted), .int64(Int64(candidate.rejectedCount)), .nullableText(candidate.error),
                .int64(Int64(candidate.inputTokens)), .int64(Int64(candidate.outputTokens)), .int64(Int64(candidate.apiCallCount)), .nullableText(candidate.requestID), .text((try? encode(candidate.rejectionReasons)) ?? "[]")
            ])
        }
    }

    func finishRun(
        id: UUID,
        finishedAt: Date = Date(),
        status: String,
        error: String? = nil,
        judgeUsed: Bool,
        judgeError: String?,
        candidateCount: Int,
        appliedCount: Int,
        finalChanges: [StealthGrammarDocumentChange],
        totalLatencyMS: Int? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        apiCallCount: Int = 0,
        requestIDs: [String] = [],
        safetyRejectedCount: Int = 0,
        rejectionReasons: [String: Int] = [:],
        agreementScore: Double? = nil
    ) {
        withLock {
            let changes = (try? encode(finalChanges)) ?? "[]"
            try? execute("UPDATE runs SET finished_at = ?, status = ?, error = ?, judge_used = ?, judge_error = ?, candidate_count = ?, applied_count = ?, final_changes = ?, total_latency_ms = COALESCE(?, total_latency_ms), input_tokens = ?, output_tokens = ?, api_call_count = ?, request_ids = ?, safety_rejected_count = ?, rejection_reasons = ?, agreement_score = ? WHERE id = ?;", bindings: [
                .double(finishedAt.timeIntervalSince1970), .text(status), .nullableText(error), .int64(judgeUsed ? 1 : 0),
                .nullableText(judgeError), .int64(Int64(candidateCount)), .int64(Int64(appliedCount)), .text(changes), .nullableInt64(totalLatencyMS.map(Int64.init)), .int64(Int64(inputTokens)), .int64(Int64(outputTokens)), .int64(Int64(apiCallCount)), .text((try? encode(requestIDs)) ?? "[]"), .int64(Int64(safetyRejectedCount)), .text((try? encode(rejectionReasons)) ?? "{}"), .nullableDouble(agreementScore), .text(id.uuidString)
            ])
        }
    }

    func saveFeedback(_ feedback: GrammarDebugFeedback) {
        withLock {
            try? execute("INSERT OR REPLACE INTO feedback (run_id, candidate_id, decision, note, created_at) VALUES (?, ?, ?, ?, ?);", bindings: [
                .text(feedback.runID.uuidString), .nullableText(feedback.candidateID), .text(feedback.decision), .nullableText(feedback.note), .double(feedback.createdAt.timeIntervalSince1970)
            ])
        }
    }

    func clearFeedback(runID: UUID, candidateID: String?) {
        withLock {
            if let candidateID {
                try? execute("DELETE FROM feedback WHERE run_id = ? AND candidate_id = ?;", bindings: [.text(runID.uuidString), .text(candidateID)])
            } else {
                try? execute("DELETE FROM feedback WHERE run_id = ? AND candidate_id IS NULL;", bindings: [.text(runID.uuidString)])
            }
        }
    }

    func recentRuns(limit: Int = 100) -> [GrammarDebugRun] {
        withLock { queryRuns("SELECT id, started_at, finished_at, strategy, judge_used, judge_error, status, error, candidate_count, applied_count, source_text, context_text, system_prompt, final_changes, configuration_snapshot, total_latency_ms, provider, model, input_tokens, output_tokens, api_call_count, request_ids, safety_rejected_count, rejection_reasons, agreement_score FROM runs ORDER BY started_at DESC LIMIT \(max(1, min(limit, 500)));", bindings: []) }
    }

    func candidates(for runID: UUID) -> [GrammarDebugCandidate] {
        withLock { queryCandidates("SELECT id, run_id, profile_id, seed, prompt_version, instructions, prompt, temperature, latency_ms, raw_changes, accepted_changes, rejected_count, error, input_tokens, output_tokens, api_call_count, request_id, rejection_reasons FROM candidates WHERE run_id = ? ORDER BY rowid;", bindings: [.text(runID.uuidString)]) }
    }

    func feedback(for runID: UUID) -> [GrammarDebugFeedback] {
        withLock {
            var result: [GrammarDebugFeedback] = []
            query("SELECT run_id, candidate_id, decision, note, created_at FROM feedback WHERE run_id = ?;", bindings: [.text(runID.uuidString)]) { statement in
                guard let run = UUID(uuidString: text(statement, 0)), let decision = textOptional(statement, 2) else { return }
                result.append(GrammarDebugFeedback(runID: run, candidateID: textOptional(statement, 1), decision: decision, note: textOptional(statement, 3), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))))
            }
            return result
        }
    }

    func analytics() -> [GrammarSeedAnalytics] {
        withLock {
            var result: [GrammarSeedAnalytics] = []
            query("""
                SELECT c.seed, c.profile_id, COUNT(*),
                       SUM(CASE WHEN json_array_length(c.raw_changes) > 0 THEN 1 ELSE 0 END),
                       SUM(json_array_length(c.accepted_changes)), SUM(c.rejected_count), AVG(c.latency_ms),
                       SUM(CASE WHEN f.decision = 'approved' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN f.decision = 'rejected' THEN 1 ELSE 0 END)
                FROM candidates c LEFT JOIN feedback f ON f.run_id = c.run_id AND f.candidate_id = c.id
                GROUP BY c.seed, c.profile_id ORDER BY c.seed;
            """, bindings: []) { statement in
                result.append(GrammarSeedAnalytics(
                    seed: UInt64(sqlite3_column_int64(statement, 0)), profileID: text(statement, 1), runCount: Int(sqlite3_column_int64(statement, 2)),
                    proposalCount: Int(sqlite3_column_int64(statement, 3)), acceptedCount: Int(sqlite3_column_int64(statement, 4)), rejectedCount: Int(sqlite3_column_int64(statement, 5)),
                    feedbackApprovedCount: Int(sqlite3_column_int64(statement, 7)), feedbackRejectedCount: Int(sqlite3_column_int64(statement, 8)), averageLatencyMS: Int(sqlite3_column_double(statement, 6))
                ))
            }
            return result
        }
    }

    func rejectionAggregates() -> [GrammarRejectionAggregate] {
        withLock {
            var counts: [String: Int] = [:]
            for run in recentRuns(limit: 500) { for (reason, count) in run.rejectionReasons { counts[reason, default: 0] += count } }
            return counts.map { GrammarRejectionAggregate(reason: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        }
    }

    func recordRequest(_ request: GrammarDebugRequest) {
        withLock { try? execute("INSERT OR REPLACE INTO requests (id, run_id, kind, provider, model, status, latency_ms, input_tokens, output_tokens, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);", bindings: [.text(request.id), .text(request.runID.uuidString), .text(request.kind), .nullableText(request.provider), .nullableText(request.model), .text(request.status), .int64(Int64(request.latencyMS)), .int64(Int64(request.inputTokens)), .int64(Int64(request.outputTokens)), .double(request.createdAt.timeIntervalSince1970)]) }
    }

    func requests(for runID: UUID) -> [GrammarDebugRequest] {
        withLock {
            var result: [GrammarDebugRequest] = []
            query("SELECT id, run_id, kind, provider, model, status, latency_ms, input_tokens, output_tokens, created_at FROM requests WHERE run_id = ? ORDER BY created_at;", bindings: [.text(runID.uuidString)]) { statement in
                guard let run = UUID(uuidString: text(statement, 1)) else { return }
                result.append(GrammarDebugRequest(id: text(statement, 0), runID: run, kind: text(statement, 2), provider: textOptional(statement, 3), model: textOptional(statement, 4), status: text(statement, 5), latencyMS: Int(sqlite3_column_int64(statement, 6)), inputTokens: Int(sqlite3_column_int64(statement, 7)), outputTokens: Int(sqlite3_column_int64(statement, 8)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))))
            }
            return result
        }
    }

    func prune(maxRuns: Int, retentionDays: Int) {
        withLock {
            let cutoff = Date().addingTimeInterval(-Double(max(1, retentionDays)) * 86_400).timeIntervalSince1970
            try? execute("DELETE FROM runs WHERE started_at < ? OR id IN (SELECT id FROM runs ORDER BY started_at DESC LIMIT -1 OFFSET ?);", bindings: [.double(cutoff), .int64(Int64(max(1, maxRuns)))])
            try? execute("VACUUM;")
        }
    }

    func export(to destination: URL? = nil, includeSource: Bool = false) throws -> URL {
        let target = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("Lima-Grammar-Debug-\(Int(Date().timeIntervalSince1970)).json")
        let payload: [[String: Any]] = withLock {
            recentRuns(limit: 500).map { run in
                func changes(_ values: [StealthGrammarDocumentChange]) -> [[String: Any]] {
                    values.map { change in
                        var value: [String: Any] = ["find": change.find, "replacement": change.replacement]
                        if let before = change.before { value["before"] = before }
                        if let after = change.after { value["after"] = after }
                        return value
                    }
                }
                var value: [String: Any] = [
                    "id": run.id.uuidString, "startedAt": run.startedAt.timeIntervalSince1970, "strategy": run.strategy.rawValue,
                    "judgeUsed": run.judgeUsed, "status": run.status, "candidateCount": run.candidateCount,
                    "appliedCount": run.appliedCount, "finalChanges": changes(run.finalChanges),
                    "totalLatencyMS": run.totalLatencyMS, "inputTokens": run.inputTokens, "outputTokens": run.outputTokens,
                    "apiCallCount": run.apiCallCount, "safetyRejectedCount": run.safetyRejectedCount,
                    "rejectionReasons": run.rejectionReasons
                ]
                if let finishedAt = run.finishedAt { value["finishedAt"] = finishedAt.timeIntervalSince1970 }
                if let judgeError = run.judgeError { value["judgeError"] = judgeError }
                if let error = run.error { value["error"] = error }
                if let snapshot = run.configurationSnapshot,
                   let snapshotData = try? encoder.encode(snapshot),
                   let snapshotObject = try? JSONSerialization.jsonObject(with: snapshotData) {
                    value["configurationSnapshot"] = snapshotObject
                }
                if includeSource {
                    if let sourceText = run.sourceText { value["sourceText"] = sourceText }
                    if let contextText = run.contextText { value["contextText"] = contextText }
                    if let systemPrompt = run.systemPrompt { value["systemPrompt"] = systemPrompt }
                }
                value["candidates"] = candidates(for: run.id).map { candidate in
                    var result: [String: Any] = [
                        "id": candidate.id, "profileID": candidate.profileID, "seed": candidate.seed,
                        "promptVersion": candidate.promptVersion, "instructions": candidate.instructions, "prompt": candidate.prompt,
                        "latencyMS": candidate.latencyMS, "rawChanges": changes(candidate.rawChanges),
                        "acceptedChanges": changes(candidate.acceptedChanges), "rejectedCount": candidate.rejectedCount,
                        "inputTokens": candidate.inputTokens, "outputTokens": candidate.outputTokens, "apiCallCount": candidate.apiCallCount,
                        "rejectionReasons": candidate.rejectionReasons
                    ]
                    if let temperature = candidate.temperature { result["temperature"] = temperature }
                    if let error = candidate.error { result["error"] = error }
                    return result
                }
                value["feedback"] = feedback(for: run.id).map { feedback in
                    var result: [String: Any] = ["decision": feedback.decision, "createdAt": feedback.createdAt.timeIntervalSince1970]
                    if let candidateID = feedback.candidateID { result["candidateID"] = candidateID }
                    if let note = feedback.note { result["note"] = note }
                    return result
                }
                return value
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "exportedAt": Date().timeIntervalSince1970, "runs": payload], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    enum StoreError: Error { case openFailed, queryFailed }
    private enum Binding { case text(String), nullableText(String?), double(Double), nullableDouble(Double?), nullableInt64(Int64?), int64(Int64) }

    private func withLock<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func close() { if let database { sqlite3_close(database); self.database = nil } }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decodeChanges(_ value: String?) -> [StealthGrammarDocumentChange] { guard let value, let data = value.data(using: .utf8) else { return [] }; return (try? decoder.decode([StealthGrammarDocumentChange].self, from: data)) ?? [] }
    private func decodeSnapshot(_ value: String?) -> GrammarRunConfigurationSnapshot? { guard let value, let data = value.data(using: .utf8) else { return nil }; return try? decoder.decode(GrammarRunConfigurationSnapshot.self, from: data) }
    private func decodeStringArray(_ value: String?) -> [String] { guard let value, let data = value.data(using: .utf8) else { return [] }; return (try? decoder.decode([String].self, from: data)) ?? [] }
    private func decodeIntMap(_ value: String?) -> [String: Int] { guard let value, let data = value.data(using: .utf8) else { return [:] }; return (try? decoder.decode([String: Int].self, from: data)) ?? [:] }

    private func executeScript(_ sql: String) throws {
        guard let database else { throw StoreError.openFailed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { if let errorMessage { sqlite3_free(errorMessage) } }
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else { throw StoreError.queryFailed }
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let database else { throw StoreError.openFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw StoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed }
    }

    private func query(_ sql: String, bindings: [Binding], row: (OpaquePointer) -> Void) {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(bindings, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement!) }
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
            case .nullableText(let value): if let value { sqlite3_bind_text(statement, position, value, -1, sqliteTransient) } else { sqlite3_bind_null(statement, position) }
            case .double(let value): sqlite3_bind_double(statement, position, value)
            case .nullableDouble(let value): if let value { sqlite3_bind_double(statement, position, value) } else { sqlite3_bind_null(statement, position) }
            case .nullableInt64(let value): if let value { sqlite3_bind_int64(statement, position, value) } else { sqlite3_bind_null(statement, position) }
            case .int64(let value): sqlite3_bind_int64(statement, position, value)
            }
        }
    }

    private func queryRuns(_ sql: String, bindings: [Binding]) -> [GrammarDebugRun] {
        var result: [GrammarDebugRun] = []
        query(sql, bindings: bindings) { statement in
            guard let id = UUID(uuidString: text(statement, 0)), let strategy = GrammarEnsembleStrategy(rawValue: text(statement, 3)) else { return }
            result.append(GrammarDebugRun(id: id, startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), finishedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), strategy: strategy, judgeUsed: sqlite3_column_int(statement, 4) != 0, judgeError: textOptional(statement, 5), status: text(statement, 6), error: textOptional(statement, 7), candidateCount: Int(sqlite3_column_int64(statement, 8)), appliedCount: Int(sqlite3_column_int64(statement, 9)), sourceText: textOptional(statement, 10), contextText: textOptional(statement, 11), systemPrompt: textOptional(statement, 12), finalChanges: decodeChanges(textOptional(statement, 13)), configurationSnapshot: decodeSnapshot(textOptional(statement, 14)), totalLatencyMS: Int(sqlite3_column_int64(statement, 15)), provider: textOptional(statement, 16), model: textOptional(statement, 17), inputTokens: Int(sqlite3_column_int64(statement, 18)), outputTokens: Int(sqlite3_column_int64(statement, 19)), apiCallCount: Int(sqlite3_column_int64(statement, 20)), requestIDs: decodeStringArray(textOptional(statement, 21)), safetyRejectedCount: Int(sqlite3_column_int64(statement, 22)), rejectionReasons: decodeIntMap(textOptional(statement, 23)), agreementScore: sqlite3_column_type(statement, 24) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 24)))
        }
        return result
    }

    private func queryCandidates(_ sql: String, bindings: [Binding]) -> [GrammarDebugCandidate] {
        var result: [GrammarDebugCandidate] = []
        query(sql, bindings: bindings) { statement in
            guard let runID = UUID(uuidString: text(statement, 1)) else { return }
            result.append(GrammarDebugCandidate(id: text(statement, 0), runID: runID, profileID: text(statement, 2), seed: UInt64(sqlite3_column_int64(statement, 3)), promptVersion: text(statement, 4), instructions: text(statement, 5), prompt: text(statement, 6), temperature: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 7), latencyMS: Int(sqlite3_column_int64(statement, 8)), rawChanges: decodeChanges(textOptional(statement, 9)), acceptedChanges: decodeChanges(textOptional(statement, 10)), rejectedCount: Int(sqlite3_column_int64(statement, 11)), error: textOptional(statement, 12), inputTokens: Int(sqlite3_column_int64(statement, 13)), outputTokens: Int(sqlite3_column_int64(statement, 14)), apiCallCount: Int(sqlite3_column_int64(statement, 15)), requestID: textOptional(statement, 16), rejectionReasons: decodeStringArray(textOptional(statement, 17))))
        }
        return result
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String { String(cString: sqlite3_column_text(statement, column)) }
    private func textOptional(_ statement: OpaquePointer?, _ column: Int32) -> String? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column) }
}
