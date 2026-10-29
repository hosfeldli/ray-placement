import Foundation
import RayPlacementCore

enum LimaReleaseImportance: String, Codable, Equatable {
    case major
    case minor
    case maintenance
}

enum LimaReleaseCategory: String, Codable, CaseIterable, Hashable {
    case newFeatures
    case improvements
    case fixes
    case removedFeatures
    case securityAndCompatibility

    var title: String {
        switch self {
        case .newFeatures: return "New Features"
        case .improvements: return "Improvements"
        case .fixes: return "Fixes"
        case .removedFeatures: return "Removed Features"
        case .securityAndCompatibility: return "Security and Compatibility"
        }
    }

    init?(heading: String) {
        let normalized = heading.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&", with: "and")
        switch normalized {
        case "new features", "features", "added": self = .newFeatures
        case "improvements", "improved", "changed": self = .improvements
        case "fixes", "fixed": self = .fixes
        case "removed features", "removed": self = .removedFeatures
        case "security and compatibility", "security", "compatibility": self = .securityAndCompatibility
        default: return nil
        }
    }
}

/// Only registered destinations may be supplied by release metadata. This
/// informational model never executes commands or changes capabilities.
enum LimaReleaseDestination: String, Codable, Equatable {
    case audioSettings = "settings.audio"
    case mailSettings = "settings.capabilities.mail"
    case versionHistory = "settings.updates"
    case notes = "notes"
}

struct LimaReleaseHighlight: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let destination: LimaReleaseDestination?
}

struct LimaReleaseSection: Codable, Equatable, Identifiable {
    let category: LimaReleaseCategory
    let markdown: String

    var id: String { category.rawValue }
}

struct LimaReleaseManifest: Codable, Equatable, Identifiable {
    let version: String
    var build: String?
    let channel: String
    let importance: LimaReleaseImportance
    let title: String
    let summary: String
    let highlights: [LimaReleaseHighlight]
    let sections: [LimaReleaseSection]
    let requiresOnboarding: Bool
    let onboardingID: String?
    let technicalDetails: String?
    let releaseURL: URL?

    var id: String { version + "-" + (build ?? "") }

    var isValid: Bool {
        let expression = try? NSRegularExpression(
            pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"
        )
        let range = NSRange(version.startIndex..<version.endIndex, in: version)
        return expression?.firstMatch(in: version, range: range) != nil
            && !title.isEmpty && title.count <= 160
            && summary.count <= 600
            && highlights.count <= 8
            && Set(highlights.map(\.id)).count == highlights.count
            && highlights.allSatisfy { $0.id.count <= 80 && !$0.id.isEmpty && $0.title.count <= 160 && !$0.title.isEmpty }
            && channel.count <= 40
            && (onboardingID?.count ?? 0) <= 80
            && sections.count <= LimaReleaseCategory.allCases.count
            && Set(sections.map(\.category)).count == sections.count
            && sections.allSatisfy { $0.markdown.utf8.count <= 20_000 }
            && (technicalDetails?.utf8.count ?? 0) <= 20_000
            && (!requiresOnboarding || (onboardingID?.isEmpty == false))
            && (releaseURL == nil || LimaReleaseNotesParser.isAllowedReleaseURL(releaseURL))
    }
}

struct LimaReleaseHistoryRecord: Codable, Equatable, Identifiable {
    let manifest: LimaReleaseManifest
    let installedAt: Date
    var id: String { manifest.id }
}

private struct LimaReleaseHistorySnapshot: Codable {
    var installed: [LimaReleaseHistoryRecord]
    var pending: LimaReleaseManifest?
}

enum LimaReleaseHistoryError: LocalizedError {
    case invalidManifest
    case damagedArchive

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "Release metadata was invalid and was not saved."
        case .damagedArchive: return "Release history needs recovery before it can be changed."
        }
    }
}

@MainActor
final class LimaReleaseHistoryStore: ObservableObject {
    static let shared = LimaReleaseHistoryStore()

    @Published private(set) var installed: [LimaReleaseHistoryRecord] = []
    @Published private(set) var pending: LimaReleaseManifest?
    @Published private(set) var storageError: String?

    private let fileURL: URL
    private let files = PrivateFileStore()

    init(fileURL: URL = ApplicationPaths.updates.appendingPathComponent("release-history.json")) {
        self.fileURL = fileURL
        let load = files.loadJSON(LimaReleaseHistorySnapshot.self, from: fileURL)
        switch load.result.state {
        case .missing: break
        case .loaded:
            if let value = load.value {
                installed = value.installed.filter { $0.manifest.isValid }
                pending = value.pending?.isValid == true ? value.pending : nil
            }
        case .corrupt, .unreadable:
            storageError = load.result.errorDescription ?? "Release history could not be read."
        }
    }

    func stageAvailable(_ manifest: LimaReleaseManifest) throws {
        guard manifest.isValid else { throw LimaReleaseHistoryError.invalidManifest }
        try save(installed: installed, pending: manifest)
    }

    /// Call only after UpdateService has consumed a successful installation
    /// receipt and checked version, build, and canonical running bundle path.
    @discardableResult
    func activateVerifiedInstall(version: String, build: String, at date: Date = Date()) throws -> LimaReleaseManifest? {
        guard var manifest = pending, manifest.version == version,
              manifest.build == nil || manifest.build == build else { return nil }
        manifest.build = build
        let record = LimaReleaseHistoryRecord(manifest: manifest, installedAt: date)
        let next = ([record] + installed.filter { $0.manifest.id != record.id })
            .prefix(40)
        try save(installed: Array(next), pending: nil)
        return manifest
    }

    func notesForInstalled(version: String, build: String) -> LimaReleaseManifest? {
        installed.first { $0.manifest.version == version && $0.manifest.build == build }?.manifest
    }

    private func save(installed nextInstalled: [LimaReleaseHistoryRecord], pending nextPending: LimaReleaseManifest?) throws {
        guard storageError == nil else { throw LimaReleaseHistoryError.damagedArchive }
        let snapshot = LimaReleaseHistorySnapshot(installed: nextInstalled, pending: nextPending)
        try files.write(snapshot, to: fileURL)
        installed = nextInstalled
        pending = nextPending
    }
}

enum LimaReleaseNotesParser {
    static func isAllowedReleaseURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.user == nil && url.password == nil
    }

    /// GitHub's release body is display-only metadata. Strip links, HTML,
    /// images, and remote URLs before handing text to the Markdown renderer.
    static func fromGitHubRelease(version: String, name: String?, body: String?, url: URL?) -> LimaReleaseManifest {
        if let body, let structured = structuredManifest(in: body, expectedVersion: version, releaseURL: url) {
            return structured
        }
        let lines = String((body ?? "").prefix(60_000)).components(separatedBy: .newlines)
        var content: [LimaReleaseCategory: [String]] = [:]
        var active: LimaReleaseCategory?
        var summary = ""
        for raw in lines.prefix(240) {
            let line = sanitize(raw)
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                let heading = raw.drop(while: { $0 == "#" || $0 == " " })
                active = LimaReleaseCategory(heading: String(heading))
                continue
            }
            guard !line.isEmpty else { continue }
            if let active {
                content[active, default: []].append(line)
            } else if summary.isEmpty {
                summary = line.trimmingCharacters(in: CharacterSet(charactersIn: "-* "))
            }
        }
        let sections = LimaReleaseCategory.allCases.compactMap { category -> LimaReleaseSection? in
            guard let lines = content[category], !lines.isEmpty else { return nil }
            return LimaReleaseSection(category: category, markdown: lines.joined(separator: "\n"))
        }
        let fallback = body?.isEmpty == false ? "Read the release notes for details." : "Release notes are not available for this update."
        let highlights = sections
            .flatMap { $0.markdown.components(separatedBy: "\n") }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .prefix(3)
            .enumerated()
            .map { index, line in
                LimaReleaseHighlight(id: "highlight-\(index)", title: String(line.dropFirst(2).prefix(120)), destination: nil)
            }
        return LimaReleaseManifest(
            version: version,
            build: nil,
            channel: "stable",
            importance: .minor,
            title: String(sanitize(name?.isEmpty == false ? (name ?? "") : "Lima \(version)").prefix(160)),
            summary: String((summary.isEmpty ? fallback : summary).prefix(600)),
            highlights: highlights,
            sections: sections,
            requiresOnboarding: false,
            onboardingID: nil,
            technicalDetails: nil,
            releaseURL: isAllowedReleaseURL(url) ? url : nil
        )
    }

    /// A fenced manifest enriches release notes without changing the signed
    /// update feed. Reject unknown routes and bind metadata to the exact
    /// published version; the running build is checked again at activation.
    private static func structuredManifest(in body: String, expectedVersion: String, releaseURL: URL?) -> LimaReleaseManifest? {
        guard body.utf8.count <= 100_000,
              let fence = body.range(of: "```lima-release"),
              let start = body[fence.upperBound...].firstIndex(of: "\n"),
              let end = body.range(of: "```", range: body.index(after: start)..<body.endIndex),
              body.distance(from: start, to: end.lowerBound) <= 40_000 else { return nil }
        let json = body[body.index(after: start)..<end.lowerBound]
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LimaReleaseManifest.self, from: data),
              decoded.version == expectedVersion else { return nil }
        let cleaned = LimaReleaseManifest(
            version: decoded.version,
            build: decoded.build,
            channel: decoded.channel,
            importance: decoded.importance,
            title: sanitize(decoded.title),
            summary: sanitize(decoded.summary),
            highlights: decoded.highlights.map {
                LimaReleaseHighlight(id: $0.id, title: sanitize($0.title), destination: $0.destination)
            },
            sections: decoded.sections.map {
                LimaReleaseSection(category: $0.category, markdown: sanitizeMarkdown($0.markdown))
            },
            requiresOnboarding: decoded.requiresOnboarding,
            onboardingID: decoded.onboardingID,
            technicalDetails: decoded.technicalDetails.map(sanitizeMarkdown),
            releaseURL: isAllowedReleaseURL(releaseURL) ? releaseURL : nil
        )
        return cleaned.isValid ? cleaned : nil
    }

    private static func sanitizeMarkdown(_ source: String) -> String {
        source.components(separatedBy: .newlines).prefix(200)
            .map(sanitize).joined(separator: "\n")
    }

    private static func sanitize(_ source: String) -> String {
        var text = String(source.prefix(600))
        text = text.replacingOccurrences(of: "!?(\\[[^\\]]+\\])\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "https?://[^\\s)]+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
