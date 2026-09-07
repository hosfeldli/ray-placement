import Foundation

public enum UpdateValidationError: Error, Equatable, Sendable {
    case emptyArchive
    case tooManyEntries
    case invalidEntry(String)
    case invalidEntryType(String)
    case versionMismatch
    case buildMismatch
    case missingRequiredFile(String)
    case invalidManifest
    case invalidSignature
}

public enum UpdateArchiveEntryType: String, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case hardLink
    case fifo
    case characterDevice
    case blockDevice
    case socket
}

/// Pure update-policy checks shared by the updater and fault-injection tests.
/// Process-level archive inspection remains in the app updater because it must
/// use macOS's zip tooling and reject filesystem link/device entries.
public enum UpdateVerificationPolicy {
    public static func validateArchiveEntries(_ entries: [String], rootName: String = "LimaUpdate", maximum: Int = 100_000) throws {
        guard !entries.isEmpty else { throw UpdateValidationError.emptyArchive }
        guard entries.count <= maximum else { throw UpdateValidationError.tooManyEntries }
        for entry in entries {
            guard UpdateArchiveEntryValidation.validate(entry, rootName: rootName) else {
                throw UpdateValidationError.invalidEntry(entry)
            }
        }
    }

    public static func validateArchiveTypes(_ types: [(path: String, type: UpdateArchiveEntryType)]) throws {
        for entry in types {
            guard entry.type == .directory || entry.type == .regularFile else {
                throw UpdateValidationError.invalidEntryType(entry.path)
            }
        }
    }

    public static func validateRequiredFiles(_ files: Set<String>, required: [String]) throws {
        for path in required where !files.contains(path) {
            throw UpdateValidationError.missingRequiredFile(path)
        }
    }

    public static func validatePackage(
        packagedVersion: String,
        expectedVersion: String,
        packagedBuild: String? = nil,
        expectedBuild: String? = nil
    ) throws {
        guard SemanticVersion(packagedVersion) == SemanticVersion(expectedVersion) else {
            throw UpdateValidationError.versionMismatch
        }
        if let expectedBuild {
            guard let packagedBuild, packagedBuild == expectedBuild else {
                throw UpdateValidationError.buildMismatch
            }
        }
    }

    public static func validateSignature(isValid: Bool) throws {
        guard isValid else { throw UpdateValidationError.invalidSignature }
    }

    public static func validateManifest(version: String, build: String, expectedVersion: String, expectedBuild: String) throws {
        try validatePackage(
            packagedVersion: version,
            expectedVersion: expectedVersion,
            packagedBuild: build,
            expectedBuild: expectedBuild
        )
    }
}
