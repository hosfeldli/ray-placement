import CryptoKit
import Foundation

enum LocalModelID: String, CaseIterable, Identifiable, Codable {
    case qwen3Fast = "qwen3-0.6b-q8"
    case qwen3Balanced = "qwen3-1.7b-q8"
    case qwen3Quality = "qwen3-4b-q4km"

    var id: String { rawValue }
}

enum LocalModelTask: String, CaseIterable, Identifiable {
    case writing
    case summary
    case formatter

    var id: String { rawValue }
    var title: String {
        switch self {
        case .writing: return "Grammar correction"
        case .summary: return "Note summaries"
        case .formatter: return "Formatter proposals"
        }
    }
}

struct LocalModelDescriptor: Identifiable, Hashable {
    let id: LocalModelID
    let title: String
    let detail: String
    let filename: String
    let downloadURL: URL?
    let sha256: String?
    let approximateBytes: Int64
    let bundled: Bool

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file) }
}

enum LocalModelCatalog {
    static let models: [LocalModelDescriptor] = [
        LocalModelDescriptor(
            id: .qwen3Fast,
            title: "Qwen3 0.6B Q8 · Fast",
            detail: "Lowest latency for summaries and simple formatter proposals.",
            filename: "Qwen3-0.6B-Q8_0.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf?download=true"),
            sha256: "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031",
            approximateBytes: 639_000_000,
            bundled: false
        ),
        LocalModelDescriptor(
            id: .qwen3Balanced,
            title: "Qwen3 1.7B Q8 · Balanced",
            detail: "Bundled default with a strong speed-to-quality balance.",
            filename: "Qwen3-1.7B-Q8_0.gguf",
            downloadURL: nil,
            sha256: nil,
            approximateBytes: 1_830_000_000,
            bundled: true
        ),
        LocalModelDescriptor(
            id: .qwen3Quality,
            title: "Qwen3 4B Q4_K_M · Quality",
            detail: "Recommended for grammar and structured corrections; slower and uses more memory.",
            filename: "Qwen3-4B-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true"),
            sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
            approximateBytes: 2_500_000_000,
            bundled: false
        )
    ]

    static func descriptor(_ identifier: LocalModelID) -> LocalModelDescriptor {
        models.first { $0.id == identifier }!
    }

    static func url(for identifier: LocalModelID) -> URL? {
        let descriptor = descriptor(identifier)
        if descriptor.bundled {
            let url = Bundle.main.resourceURL?
                .appendingPathComponent("Qwen", isDirectory: true)
                .appendingPathComponent(descriptor.filename)
            return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
        let url = ApplicationPaths.models.appendingPathComponent(descriptor.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func isInstalled(_ identifier: LocalModelID) -> Bool { url(for: identifier) != nil }
}

@MainActor
final class ModelDownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloadService()

    @Published private(set) var downloading: LocalModelID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "Optional models are downloaded only when you choose Install."
    @Published private(set) var installedGeneration = 0

    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var expectedSHA256: String?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func install(_ identifier: LocalModelID) {
        guard downloading == nil else { return }
        let descriptor = LocalModelCatalog.descriptor(identifier)
        guard !descriptor.bundled, let url = descriptor.downloadURL, let sha256 = descriptor.sha256 else { return }
        do { try ApplicationPaths.prepare() } catch {
            status = error.localizedDescription
            return
        }
        downloading = identifier
        progress = 0
        status = "Downloading \(descriptor.title)…"
        destination = ApplicationPaths.models.appendingPathComponent(descriptor.filename)
        expectedSHA256 = sha256
        task = session.downloadTask(with: url)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        reset(status: "Model download cancelled.")
    }

    func remove(_ identifier: LocalModelID) {
        guard !LocalModelCatalog.descriptor(identifier).bundled else { return }
        guard let url = LocalModelCatalog.url(for: identifier) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            installedGeneration += 1
            status = "Removed \(LocalModelCatalog.descriptor(identifier).title)."
        } catch {
            status = "Could not remove the model: \(error.localizedDescription)"
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in self.progress = min(max(value, 0), 1) }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temporaryCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("RayPlacement-model-\(UUID().uuidString).download")
        do {
            try FileManager.default.copyItem(at: location, to: temporaryCopy)
        } catch {
            Task { @MainActor in self.reset(status: "The model download could not be staged: \(error.localizedDescription)") }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let digest = try? Self.sha256(of: temporaryCopy)
            await MainActor.run {
                guard let expected = self.expectedSHA256,
                      digest?.caseInsensitiveCompare(expected) == .orderedSame,
                      let destination = self.destination else {
                    try? FileManager.default.removeItem(at: temporaryCopy)
                    self.reset(status: "Model verification failed. Nothing was installed.")
                    return
                }
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: temporaryCopy, to: destination)
                    self.installedGeneration += 1
                    self.reset(status: "Verified and installed \(destination.lastPathComponent).")
                } catch {
                    try? FileManager.default.removeItem(at: temporaryCopy)
                    self.reset(status: "The verified model could not be installed: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            guard self.downloading != nil else { return }
            self.reset(status: "Model download failed: \(error.localizedDescription)")
        }
    }

    private func reset(status: String) {
        task = nil
        downloading = nil
        destination = nil
        expectedSHA256 = nil
        progress = 0
        self.status = status
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
