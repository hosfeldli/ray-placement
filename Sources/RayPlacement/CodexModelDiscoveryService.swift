import Darwin
import Foundation

/// Reads the locally installed Codex app-server catalog without running an
/// inference or exposing Lima tools to the Codex process.
struct CodexModelDiscoveryService {
    enum Failure: LocalizedError, Equatable {
        case missingCLI
        case invalidResponse
        case unavailable

        var errorDescription: String? {
            switch self {
            case .missingCLI: return "Codex CLI is not installed."
            case .invalidResponse: return "Codex returned an unreadable model catalog."
            case .unavailable: return "Codex model discovery did not complete. Try Refresh Models."
            }
        }
    }

    private static let maximumResponseBytes = 4 * 1024 * 1024
    private static let maximumPages = 16
    private static let maximumModels = 500

    /// A cancelled discovery must not launch a process after cancellation or
    /// leave a CLI that ignores SIGTERM holding the app-server pipes open.
    private final class ProcessLifetime: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var cancelled = false
        private var timedOut = false

        init(_ process: Process) { self.process = process }

        func launch() throws {
            lock.lock()
            guard !cancelled else { lock.unlock(); throw CancellationError() }
            do { try process.run() } catch {
                lock.unlock()
                throw Failure.unavailable
            }
            lock.unlock()
        }

        func checkCancelled() throws {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw CancellationError() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            terminateLocked()
            lock.unlock()
        }

        func stop() {
            lock.lock()
            terminateLocked()
            lock.unlock()
        }

        func expire() {
            lock.lock()
            timedOut = true
            terminateLocked()
            lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        private func terminateLocked() {
            guard process.isRunning else { return }
            process.terminate()
            let process = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    static func listModels(executableURL: URL?, timeout: TimeInterval = 20) async throws -> [AIModelOption] {
        guard let executableURL else { throw Failure.missingCLI }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        // A CLI that exits between requests must produce EPIPE, not deliver
        // SIGPIPE to the entire Lima process.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw Failure.unavailable
        }
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Discovery never displays raw CLI diagnostics, which may contain
        // account data. Discard stderr instead of retaining a second pipe.
        process.standardError = FileHandle.nullDevice

        let lifetime = ProcessLifetime(process)
        do {
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try run(lifetime: lifetime, input: input, output: output, timeout: timeout)
                }.value
            } onCancel: {
                lifetime.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if lifetime.didTimeOut { throw Failure.unavailable }
            if let failure = error as? Failure { throw failure }
            throw Failure.unavailable
        }
    }

    private static func run(lifetime: ProcessLifetime, input: Pipe, output: Pipe, timeout: TimeInterval) throws -> [AIModelOption] {
        try lifetime.checkCancelled()
        try lifetime.launch()
        let process = lifetime.process
        let timeoutWork = DispatchWorkItem { lifetime.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout), execute: timeoutWork)
        defer {
            timeoutWork.cancel()
            lifetime.stop()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
        }

        var reader = LineReader(handle: output.fileHandleForReading)
        try send(["id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": "Lima", "version": "1"]]], to: input)
        _ = try readResult(id: 1, reader: &reader, lifetime: lifetime)
        try send(["method": "initialized"], to: input)

        var options = [AIModelOption(id: "default", displayName: "Default", supportsReasoning: false)]
        var seen = Set(["default"])
        var cursor: String?
        for page in 0..<maximumPages {
            try lifetime.checkCancelled()
            let id = page + 2
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            try send(["id": id, "method": "model/list", "params": params], to: input)
            let result = try readResult(id: id, reader: &reader, lifetime: lifetime)
            let parsed = try parseModelListResult(result)
            for option in parsed.models where seen.insert(option.id).inserted {
                options.append(option)
                if options.count >= maximumModels { return options }
            }
            guard let nextCursor = parsed.nextCursor, nextCursor != cursor else { return options }
            cursor = nextCursor
        }
        throw Failure.invalidResponse
    }

    private static func send(_ object: [String: Any], to input: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private static func readResult(id: Int, reader: inout LineReader, lifetime: ProcessLifetime) throws -> [String: Any] {
        for _ in 0..<200 {
            try lifetime.checkCancelled()
            guard let line = try reader.nextLine(),
                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw Failure.invalidResponse
            }
            guard message["id"] as? Int == id else { continue }
            guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                throw Failure.unavailable
            }
            return result
        }
        throw Failure.invalidResponse
    }

    static func parseModelListResult(_ result: [String: Any]) throws -> (models: [AIModelOption], nextCursor: String?) {
        guard let entries = result["data"] as? [[String: Any]] else { throw Failure.invalidResponse }
        let models = entries.compactMap { entry -> AIModelOption? in
            guard entry["hidden"] as? Bool != true,
                  let id = (entry["model"] as? String) ?? (entry["id"] as? String),
                  CLIChatProviderClient.isValidModelID(id), id != "default" else { return nil }
            let name = (entry["displayName"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { ($0["reasoningEffort"] as? String).flatMap(AIReasoningEffort.init(rawValue:)) }
            return AIModelOption(id: id, displayName: name, supportsReasoning: !efforts.isEmpty,
                                 supportedReasoningEfforts: efforts)
        }
        return (models, result["nextCursor"] as? String)
    }

    private struct LineReader {
        let handle: FileHandle
        var buffer = Data()
        var totalBytes = 0

        mutating func nextLine() throws -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    return line
                }
                // readData(ofLength:) can wait for the entire requested count,
                // deadlocking the request/response protocol on a short line.
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return nil }
                totalBytes += chunk.count
                guard totalBytes <= maximumResponseBytes else { throw Failure.invalidResponse }
                buffer.append(chunk)
            }
        }
    }
}
