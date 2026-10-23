import Combine
import Foundation
import Network

struct NetworkQualityResult: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Double
    let downloadMbps: Double
    let uploadMbps: Double
    let idleLatencyMilliseconds: Double?
    let responsiveness: String?
    let interfaceName: String?
    let method: String
}

/// Accepts the human-readable SUMMARY produced by the macOS networkQuality
/// utility. An unrecognized format fails instead of reporting made-up numbers.
enum NetworkQualitySummaryParser {
    static func parse(_ output: String, id: UUID, startedAt: Date,
                      durationSeconds: Double) -> NetworkQualityResult? {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func value(after labels: [String]) -> String? {
            for line in lines {
                let lower = line.lowercased()
                for label in labels where lower.hasPrefix(label) {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        guard let downloadText = value(after: ["download capacity:", "download:"]),
              let uploadText = value(after: ["upload capacity:", "upload:"]),
              let download = megabitsPerSecond(downloadText),
              let upload = megabitsPerSecond(uploadText) else { return nil }
        let latency = value(after: ["idle latency:", "idle latency "]).flatMap(firstNumber)
        let responsiveness = value(after: ["responsiveness:", "download responsiveness:"])
        let interfaceName = value(after: ["interface:", "network interface:"])
        return NetworkQualityResult(
            id: id, startedAt: startedAt, durationSeconds: durationSeconds,
            downloadMbps: download, uploadMbps: upload,
            idleLatencyMilliseconds: latency, responsiveness: responsiveness,
            interfaceName: interfaceName, method: "macOS networkQuality"
        )
    }

    private static func megabitsPerSecond(_ text: String) -> Double? {
        guard let amount = firstNumber(text), amount.isFinite, amount >= 0 else { return nil }
        let lower = text.lowercased()
        if lower.contains("gbps") || lower.contains("gbit") { return amount * 1_000 }
        if lower.contains("mbps") || lower.contains("mbit") { return amount }
        if lower.contains("kbps") || lower.contains("kbit") { return amount / 1_000 }
        return nil
    }

    private static func firstNumber(_ text: String) -> Double? {
        guard let range = text.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(text[range])
    }
}

@MainActor
final class NetworkQualityService: ObservableObject {
    static let shared = NetworkQualityService()

    enum Phase: String, Sendable {
        case idle, running, cancelling, completed, cancelled, failed
    }

    enum QualityError: LocalizedError {
        case alreadyRunning
        case unavailable
        case unrecognizedOutput

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "A network quality test is already running."
            case .unavailable: "The macOS networkQuality utility is unavailable."
            case .unrecognizedOutput: "networkQuality finished, but Lima could not read its result format."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var startedAt: Date?
    @Published private(set) var latestResult: NetworkQualityResult?
    @Published private(set) var results: [NetworkQualityResult] = []
    @Published private(set) var connectionDescription = "Checking connection…"
    @Published private(set) var errorMessage: String?

    private let executableURL: URL
    private let historyURL: URL
    private var process: Process?
    private var cancellationRequested = false
    private var pathMonitor: NWPathMonitor?

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/networkQuality"),
         historyURL: URL? = nil) {
        self.executableURL = executableURL
        self.historyURL = historyURL ?? ApplicationPaths.applicationSupport
            .appendingPathComponent("Network Quality/history.json")
        if let data = try? Data(contentsOf: self.historyURL),
           let decoded = try? JSONDecoder().decode([NetworkQualityResult].self, from: data) {
            results = Array(decoded.prefix(100))
            latestResult = results.first
        }
    }

    func refreshConnection() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let description: String
            if path.status != .satisfied {
                description = "Offline"
            } else if path.usesInterfaceType(.wifi) {
                description = "Wi-Fi"
            } else if path.usesInterfaceType(.wiredEthernet) {
                description = "Ethernet"
            } else if path.usesInterfaceType(.cellular) {
                description = "Cellular"
            } else {
                description = "Other network"
            }
            Task { @MainActor [weak self, weak monitor] in
                self?.connectionDescription = description
                monitor?.cancel()
                if self?.pathMonitor === monitor { self?.pathMonitor = nil }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.lima.network-path"))
    }

    @discardableResult
    func start() throws -> UUID {
        guard process == nil else { throw QualityError.alreadyRunning }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw QualityError.unavailable
        }
        let pipe = Pipe()
        let launched = Process()
        launched.executableURL = executableURL
        launched.standardOutput = pipe
        launched.standardError = pipe
        let id = UUID()
        let began = Date()
        try launched.run()
        process = launched
        phase = .running
        activeRunID = id
        startedAt = began
        errorMessage = nil
        cancellationRequested = false
        refreshConnection()

        // Drain stdout/stderr off the main actor throughout the test. A bounded
        // capture is enough for the summary while the pipe is always drained.
        Task.detached(priority: .utility) { [weak self] in
            var captured = Data()
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 4_096),
                      !chunk.isEmpty {
                    if captured.count < 131_072 {
                        captured.append(chunk.prefix(131_072 - captured.count))
                    }
                }
            } catch {
                // Process termination can close the pipe while it is draining.
            }
            launched.waitUntilExit()
            let output = String(decoding: captured, as: UTF8.self)
            await self?.finish(id: id, launched: launched, began: began,
                               exitCode: launched.terminationStatus, output: output)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard let self, self.activeRunID == id, self.process === launched else { return }
            self.cancel()
            self.errorMessage = "The network quality test exceeded five minutes and was stopped."
        }
        return id
    }

    func cancel() {
        guard let launched = process, launched.isRunning else { return }
        cancellationRequested = true
        phase = .cancelling
        launched.interrupt()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.process === launched, launched.isRunning else { return }
            launched.terminate()
        }
    }

    private func finish(id: UUID, launched: Process, began: Date,
                        exitCode: Int32, output: String) {
        guard process === launched, activeRunID == id else { return }
        process = nil
        activeRunID = nil
        startedAt = nil
        let elapsed = max(0, Date().timeIntervalSince(began))
        if cancellationRequested {
            phase = .cancelled
            cancellationRequested = false
            return
        }
        guard exitCode == 0 else {
            phase = .failed
            errorMessage = "networkQuality exited with code \(exitCode)."
            return
        }
        guard let parsed = NetworkQualitySummaryParser.parse(
            output, id: id, startedAt: began, durationSeconds: elapsed
        ) else {
            phase = .failed
            errorMessage = QualityError.unrecognizedOutput.localizedDescription
            return
        }
        latestResult = parsed
        phase = .completed
        results.insert(parsed, at: 0)
        if results.count > 100 { results.removeLast(results.count - 100) }
        persistHistory()
    }

    private func persistHistory() {
        let snapshot = results
        let url = historyURL
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: url.path)
            } catch {
                // The completed in-memory result remains visible for this session.
            }
        }
    }
}
