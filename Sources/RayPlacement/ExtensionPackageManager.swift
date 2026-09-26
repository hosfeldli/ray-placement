import Foundation
import RayPlacementCore

/// Stable lifecycle state for an extension package. Filesystem presence is not
/// enough to describe a package because bundled extensions can be logically
/// removed without deleting Lima's shipped resources.
enum ExtensionPackageState: String, Codable, CaseIterable, Sendable {
    case notInstalled
    case downloading
    case verifying
    case staging
    case installed
    case updateAvailable
    case failed
    case disabled
    case logicallyRemoved
}

enum ExtensionPackageProvenance: String, Codable, CaseIterable, Sendable {
    case bundled
    case userInstalled
    case localDeveloper
    case catalogInstalled
}

struct ExtensionPackageRecord: Codable, Sendable, Identifiable {
    let id: String
    var name: String
    var version: String?
    var state: ExtensionPackageState
    var provenance: ExtensionPackageProvenance
    var installedAt: Date?
    var updatedAt: Date
    var lastError: String?
    var manifestHash: String?

    init(id: String, name: String, version: String? = nil, state: ExtensionPackageState, provenance: ExtensionPackageProvenance, installedAt: Date? = nil, updatedAt: Date = Date(), lastError: String? = nil, manifestHash: String? = nil) {
        self.id = id; self.name = name; self.version = version; self.state = state; self.provenance = provenance
        self.installedAt = installedAt; self.updatedAt = updatedAt; self.lastError = lastError; self.manifestHash = manifestHash
    }
}

struct ExtensionPackageTransaction: Sendable {
    let id: UUID
    let packageID: String
    let previous: ExtensionPackageRecord?
    let stagedURL: URL?
    let validationPassed: Bool
    let committed: Bool
    let error: String?
}

/// Transactional package lifecycle registry. Installation work is supplied by
/// the store facade, while this type owns serialization, state transitions,
/// provenance, rollback metadata, and bundled-pack tombstones.
@MainActor
final class ExtensionPackageManager: ObservableObject {
    static let shared = ExtensionPackageManager()
    private static let recordsKey = "lima.extensionPackageRecords"
    private static let removedBundledKey = "lima.logicallyRemovedBundledExtensions"

    @Published private(set) var records: [String: ExtensionPackageRecord]
    private let defaults: UserDefaults
    private var activePackageID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = (try? JSONDecoder().decode([String: ExtensionPackageRecord].self, from: defaults.data(forKey: Self.recordsKey) ?? Data())) ?? [:]
    }

    func record(for id: String) -> ExtensionPackageRecord? { records[id] }

    func register(id: String, name: String, version: String?, provenance: ExtensionPackageProvenance, state: ExtensionPackageState = .installed, manifestHash: String? = nil) {
        var value = records[id] ?? ExtensionPackageRecord(id: id, name: name, version: version, state: state, provenance: provenance)
        value.name = name; value.version = version; value.provenance = provenance; value.state = state; value.manifestHash = manifestHash; value.updatedAt = Date()
        records[id] = value; persist()
    }

    func transition(_ state: ExtensionPackageState, id: String, error: String? = nil) {
        guard var value = records[id] else { return }
        value.state = state; value.lastError = error; value.updatedAt = Date()
        if state == .installed && value.installedAt == nil { value.installedAt = Date() }
        records[id] = value; persist()
    }

    /// Serializes package operations and makes failure visible as a stable
    /// failed state. The operation must stage and atomically replace the package
    /// directory; the manager never exposes a half-installed state.
    func performInstall(id: String, name: String, version: String?, provenance: ExtensionPackageProvenance, operation: () async throws -> Void) async -> ExtensionPackageTransaction {
        guard activePackageID == nil else {
            return ExtensionPackageTransaction(id: UUID(), packageID: id, previous: records[id], stagedURL: nil, validationPassed: false, committed: false, error: "Another extension package operation is already running.")
        }
        activePackageID = id
        let transactionID = UUID()
        let previous = records[id]
        register(id: id, name: name, version: version, provenance: provenance, state: .downloading)
        do {
            transition(.verifying, id: id)
            try await operation()
            transition(.installed, id: id)
            activePackageID = nil
            return ExtensionPackageTransaction(id: transactionID, packageID: id, previous: previous, stagedURL: nil, validationPassed: true, committed: true, error: nil)
        } catch {
            // Restore the complete prior record as well as the staged package
            // directory. Keeping the attempted version here would make the UI
            // claim that an update succeeded even though its files were rolled
            // back. New installs retain a failed record for retry diagnostics.
            var failed = previous ?? ExtensionPackageRecord(
                id: id,
                name: name,
                version: version,
                state: .failed,
                provenance: provenance
            )
            failed.state = previous?.state ?? .failed
            failed.lastError = error.localizedDescription
            failed.updatedAt = Date()
            records[id] = failed
            persist()
            activePackageID = nil
            return ExtensionPackageTransaction(
                id: transactionID,
                packageID: id,
                previous: previous,
                stagedURL: nil,
                validationPassed: false,
                committed: false,
                error: error.localizedDescription
            )
        }
    }

    func logicallyRemoveBundled(id: String) {
        var removed = logicallyRemovedBundled()
        removed.insert(id)
        defaults.set(Array(removed).sorted(), forKey: Self.removedBundledKey)
        if records[id] != nil { transition(.logicallyRemoved, id: id) }
    }

    func restoreBundled(id: String) {
        var removed = logicallyRemovedBundled(); removed.remove(id)
        defaults.set(Array(removed).sorted(), forKey: Self.removedBundledKey)
        if records[id] != nil { transition(.installed, id: id) }
    }

    func isLogicallyRemoved(_ id: String) -> Bool {
        let values = defaults.array(forKey: Self.removedBundledKey) as? [String] ?? []
        return Set(values).contains(id)
    }

    func logicallyRemovedBundled() -> Set<String> {
        Set(defaults.array(forKey: Self.removedBundledKey) as? [String] ?? [])
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.recordsKey)
    }
}
