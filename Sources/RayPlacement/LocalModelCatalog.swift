import CryptoKit
import Foundation

enum LocalModelID: String, CaseIterable, Identifiable, Codable {
    case qwen3Fast = "qwen3-0.6b-q8"
    case qwen3Balanced = "qwen3-1.7b-q8"
    case qwen3Quality = "qwen3-4b-q4km"
    case mistralCompact = "ministral-3-3b-q4km"
    case gemmaQuality = "gemma-3-4b-q4"
    case phi4Large = "phi-4-tq2"

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

struct LocalModelDescriptor: Identifiable, Hashable, Sendable {
    let id: LocalModelID
    let title: String
    let detail: String
    let filename: String
    let downloadURL: URL?
    let sha256: String?
    let approximateBytes: Int64
    let bundled: Bool
    let vendor: String
    let modelPageURL: URL?

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
            bundled: false,
            vendor: "Alibaba · Qwen",
            modelPageURL: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF")
        ),
        LocalModelDescriptor(
            id: .qwen3Balanced,
            title: "Qwen3 1.7B Q8 · Balanced",
            detail: "Bundled default with a strong speed-to-quality balance.",
            filename: "Qwen3-1.7B-Q8_0.gguf",
            downloadURL: nil,
            sha256: nil,
            approximateBytes: 1_830_000_000,
            bundled: true,
            vendor: "Alibaba · Qwen",
            modelPageURL: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF")
        ),
        LocalModelDescriptor(
            id: .qwen3Quality,
            title: "Qwen3 4B Q4_K_M · Quality",
            detail: "Recommended for grammar and structured corrections; slower and uses more memory.",
            filename: "Qwen3-4B-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf?download=true"),
            sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
            approximateBytes: 2_500_000_000,
            bundled: false,
            vendor: "Alibaba · Qwen",
            modelPageURL: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF")
        ),
        LocalModelDescriptor(
            id: .mistralCompact,
            title: "Ministral 3 3B Q4_K_M · Mistral",
            detail: "Official compact Mistral model for writing, summaries, and tool workflows.",
            filename: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf?download=true"),
            sha256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8",
            approximateBytes: 2_147_023_008,
            bundled: false,
            vendor: "Mistral AI",
            modelPageURL: URL(string: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF")
        ),
        LocalModelDescriptor(
            id: .gemmaQuality,
            title: "Gemma 3 4B Q4 · Google",
            detail: "Official Google quality model. Import after accepting Google's model terms.",
            filename: "gemma-3-4b-it-q4_0.gguf",
            downloadURL: nil,
            sha256: "76aed0a8285b83102f18b5d60e53c70d09eb4e9917a20ce8956bd546452b56e2",
            approximateBytes: 3_155_051_328,
            bundled: false,
            vendor: "Google",
            modelPageURL: URL(string: "https://huggingface.co/google/gemma-3-4b-it-qat-q4_0-gguf")
        ),
        LocalModelDescriptor(
            id: .phi4Large,
            title: "Phi-4 TQ2 · Microsoft",
            detail: "Official Microsoft high-capacity model. Larger and intended for Macs with ample memory.",
            filename: "phi-4-TQ2_0.gguf",
            downloadURL: URL(string: "https://huggingface.co/microsoft/phi-4-gguf/resolve/main/phi-4-TQ2_0.gguf?download=true"),
            sha256: "c3ed993354f92e1bd4bd1c64e879bb14c085811c817ca1aa9ffac4cc7f6fa665",
            approximateBytes: 4_230_074_560,
            bundled: false,
            vendor: "Microsoft",
            modelPageURL: URL(string: "https://huggingface.co/microsoft/phi-4-gguf")
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
    private var importTask: Task<Void, Never>?
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
        importTask?.cancel()
        reset(status: "Model transfer cancelled.")
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

    func importModel(_ identifier: LocalModelID, from source: URL) {
        guard downloading == nil else { return }
        let descriptor = LocalModelCatalog.descriptor(identifier)
        guard !descriptor.bundled else { return }
        do {
            try ApplicationPaths.prepare()
            let handle = try FileHandle(forReadingFrom: source)
            let header = try handle.read(upToCount: 4) ?? Data()
            try? handle.close()
            guard header == Data([0x47, 0x47, 0x55, 0x46]) else {
                status = "That file is not a valid GGUF model."
                return
            }
            let destination = ApplicationPaths.models.appendingPathComponent(descriptor.filename)
            let staged = ApplicationPaths.models.appendingPathComponent(".\(UUID().uuidString).import")
            downloading = identifier
            status = "Copying and verifying \(descriptor.title)…"
            importTask = Task.detached(priority: .utility) {
                do {
                    try FileManager.default.copyItem(at: source, to: staged)
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: staged)
                        return
                    }
                    if let expected = descriptor.sha256 {
                        let digest = try Self.sha256(of: staged)
                        guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
                            throw ModelImportError.checksumMismatch
                        }
                    }
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: staged)
                        return
                    }
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: staged, to: destination)
                        await ModelDownloadService.shared.finishImport(
                            identifier,
                            status: "Verified and imported \(descriptor.title).",
                            installed: true
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: staged)
                        await ModelDownloadService.shared.finishImport(
                            identifier,
                            status: "The verified model could not be installed: \(error.localizedDescription)",
                            installed: false
                        )
                    }
                } catch {
                    try? FileManager.default.removeItem(at: staged)
                    let message = error is ModelImportError
                        ? "Model verification failed. Choose the exact official file shown in the model library."
                        : "The model could not be imported: \(error.localizedDescription)"
                    await ModelDownloadService.shared.finishImport(identifier, status: message, installed: false)
                }
            }
        } catch {
            status = "The model could not be imported: \(error.localizedDescription)"
        }
    }

    private enum ModelImportError: Error {
        case checksumMismatch
    }

    private func finishImport(_ identifier: LocalModelID, status: String, installed: Bool) {
        guard downloading == identifier else { return }
        if installed { installedGeneration += 1 }
        reset(status: status)
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
        importTask = nil
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
