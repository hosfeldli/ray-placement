import Foundation

public enum PrivateFileLoadState: Equatable, Sendable {
    case missing
    case loaded
    case corrupt
    case unreadable
}

public struct PrivateFileLoadResult: Sendable {
    public let state: PrivateFileLoadState
    public let data: Data?
    public let recoveryURL: URL?
    public let errorDescription: String?

    public init(state: PrivateFileLoadState, data: Data? = nil, recoveryURL: URL? = nil, errorDescription: String? = nil) {
        self.state = state
        self.data = data
        self.recoveryURL = recoveryURL
        self.errorDescription = errorDescription
    }
}

public enum PrivateFileStoreError: LocalizedError, Equatable, Sendable {
    case encodingFailed
    case directoryCreationFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "The data could not be encoded."
        case .directoryCreationFailed(let message): return "The private storage directory could not be prepared: \(message)"
        case .writeFailed(let message): return "The private file could not be saved: \(message)"
        }
    }
}

/// Atomic, permission-hardened storage for local private data.
///
/// The utility deliberately never turns malformed data into an empty value.
/// Callers receive a state and, for damaged files, a recovery copy path.
public struct PrivateFileStore: Sendable {
    public var recoveryDirectoryName: String
    public var backupDirectoryName: String

    public init(recoveryDirectoryName: String = "Recovery", backupDirectoryName: String = "Backups") {
        self.recoveryDirectoryName = recoveryDirectoryName
        self.backupDirectoryName = backupDirectoryName
    }

    @discardableResult
    public func prepareDirectory(_ directory: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try setPermissions(directory, mode: 0o700)
            return directory
        } catch {
            throw PrivateFileStoreError.directoryCreationFailed(error.localizedDescription)
        }
    }

    public func loadData(from url: URL) -> PrivateFileLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return PrivateFileLoadResult(state: .missing)
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return PrivateFileLoadResult(state: .loaded, data: data)
        } catch {
            return PrivateFileLoadResult(
                state: .unreadable,
                recoveryURL: makeRecoveryCopy(of: url),
                errorDescription: error.localizedDescription
            )
        }
    }

    public func loadJSON<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> (result: PrivateFileLoadResult, value: T?) {
        let result = loadData(from: url)
        guard result.state == .loaded, let data = result.data else { return (result, nil) }
        do {
            return (result, try decoder.decode(type, from: data))
        } catch {
            let recoveryURL = makeRecoveryCopy(of: url)
            return (
                PrivateFileLoadResult(
                    state: .corrupt,
                    recoveryURL: recoveryURL,
                    errorDescription: error.localizedDescription
                ),
                nil
            )
        }
    }

    public func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder(), backupExisting: Bool = true) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw PrivateFileStoreError.encodingFailed
        }
        try write(data: data, to: url, backupExisting: backupExisting)
    }

    public func write(data: Data, to url: URL, backupExisting: Bool = true) throws {
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        if backupExisting, FileManager.default.fileExists(atPath: url.path) {
            _ = makeBackup(of: url)
        }

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            try setPermissions(temporary, mode: 0o600)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            try setPermissions(url, mode: 0o600)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PrivateFileStoreError.writeFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func makeBackup(of url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let directory = url.deletingLastPathComponent().appendingPathComponent(backupDirectoryName, isDirectory: true)
        do {
            try prepareDirectory(directory)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let destination = directory.appendingPathComponent("\(url.lastPathComponent).\(stamp).bak")
            try FileManager.default.copyItem(at: url, to: destination)
            try setPermissions(destination, mode: 0o600)
            return destination
        } catch {
            return nil
        }
    }

    private func makeRecoveryCopy(of url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let directory = url.deletingLastPathComponent().appendingPathComponent(recoveryDirectoryName, isDirectory: true)
        do {
            try prepareDirectory(directory)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let destination = directory.appendingPathComponent("\(url.lastPathComponent).\(stamp).recovery")
            try FileManager.default.copyItem(at: url, to: destination)
            try setPermissions(destination, mode: 0o600)
            return destination
        } catch {
            return nil
        }
    }

    private func setPermissions(_ url: URL, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
