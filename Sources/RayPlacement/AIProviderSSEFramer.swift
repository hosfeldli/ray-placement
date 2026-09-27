import Foundation

struct AIProviderSSEFrame {
    var event: String
    var data: String
}

/// Shared byte-level SSE framing. Bounds apply before buffering, including
/// unterminated lines and comment-only streams. A failure is terminal.
struct AIProviderSSEFramer {
    enum Failure: LocalizedError {
        case limitExceeded
        var errorDescription: String? { "The provider stream exceeded Lima's safety limit." }
    }

    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    private let maximumStreamBytes: Int
    private let maximumDataLines: Int
    private var line: [UInt8] = []
    private var event = ""
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var streamBytes = 0
    private var previousWasCR = false
    private(set) var failed = false

    init(maximumLineBytes: Int = 1_048_576, maximumEventBytes: Int = 2_097_152,
         maximumStreamBytes: Int = 33_554_432, maximumDataLines: Int = 4_096) {
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumEventBytes = max(1, maximumEventBytes)
        self.maximumStreamBytes = max(1, maximumStreamBytes)
        self.maximumDataLines = max(1, maximumDataLines)
    }

    mutating func append(_ byte: UInt8) throws -> AIProviderSSEFrame? {
        guard !failed, streamBytes < maximumStreamBytes else { throw fail() }
        streamBytes += 1
        if byte == 0x0A, previousWasCR {
            previousWasCR = false
            return nil
        }
        previousWasCR = byte == 0x0D
        if byte == 0x0D || byte == 0x0A {
            let value = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return try consume(value)
        }
        guard line.count < maximumLineBytes else { throw fail() }
        line.append(byte)
        return nil
    }

    /// Used by callers that already preserve SSE blank lines.
    mutating func append(line value: String) throws -> AIProviderSSEFrame? {
        guard !failed, value.utf8.count <= maximumLineBytes,
              value.utf8.count < maximumStreamBytes - streamBytes else { throw fail() }
        streamBytes += value.utf8.count + 1
        return try consume(value)
    }

    mutating func finish() throws -> AIProviderSSEFrame? {
        guard !failed else { throw Failure.limitExceeded }
        if !line.isEmpty {
            let value = String(decoding: line, as: UTF8.self)
            line.removeAll()
            _ = try consume(value)
        }
        return flush()
    }

    private mutating func consume(_ value: String) throws -> AIProviderSSEFrame? {
        if value.isEmpty { return flush() }
        guard value.utf8.count < maximumEventBytes - eventBytes else { throw fail() }
        eventBytes += value.utf8.count + 1
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var payload = parts.count == 2 ? String(parts[1]) : ""
        // SSE removes only one optional space, not data's trailing whitespace.
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if field == "event" { event = payload }
        if field == "data" {
            guard dataLines.count < maximumDataLines else { throw fail() }
            dataLines.append(payload)
        }
        return nil
    }

    private mutating func flush() -> AIProviderSSEFrame? {
        defer { event = ""; dataLines = []; eventBytes = 0 }
        guard !dataLines.isEmpty else { return nil }
        return AIProviderSSEFrame(event: event, data: dataLines.joined(separator: "\n"))
    }

    private mutating func fail() -> Failure {
        failed = true
        line = []; event = ""; dataLines = []; eventBytes = 0
        return .limitExceeded
    }
}
