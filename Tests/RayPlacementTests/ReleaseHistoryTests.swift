import Foundation
import Testing
@testable import RayPlacement

@MainActor
struct ReleaseHistoryTests {
    private func temporaryHistoryURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lima-ReleaseHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("release-history.json")
    }

    private func manifest(version: String = "4.0.0", build: String? = nil) -> LimaReleaseManifest {
        LimaReleaseManifest(
            version: version,
            build: build,
            channel: "stable",
            importance: .major,
            title: "A more focused Lima",
            summary: "Native audio controls and a simpler workspace.",
            highlights: [
                LimaReleaseHighlight(id: "audio-output", title: "Audio Output Selection", destination: .audioSettings)
            ],
            sections: [
                LimaReleaseSection(category: .newFeatures, markdown: "- Select a system audio output."),
                LimaReleaseSection(category: .removedFeatures, markdown: "- The dedicated Workflows feature is retired.")
            ],
            requiresOnboarding: true,
            onboardingID: "major-release-introduction",
            technicalDetails: nil,
            releaseURL: URL(string: "https://github.com/hosfeldli/ray-placement/releases/tag/v4.0.0")
        )
    }

    @Test
    func availableNotesRemainPendingUntilMatchingVerifiedReceipt() throws {
        let url = try temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let archive = LimaReleaseHistoryStore(fileURL: url)
        try archive.stageAvailable(manifest())
        #expect(archive.installed.isEmpty)
        #expect(archive.pending?.version == "4.0.0")
        #expect(try archive.activateVerifiedInstall(version: "3.9.9", build: "4000000") == nil)
        #expect(archive.installed.isEmpty)

        let restored = LimaReleaseHistoryStore(fileURL: url)
        #expect(restored.pending?.version == "4.0.0")
        let activated = try restored.activateVerifiedInstall(version: "4.0.0", build: "4000000")
        #expect(activated?.build == "4000000")
        #expect(restored.pending == nil)
        #expect(restored.notesForInstalled(version: "4.0.0", build: "4000000")?.title == "A more focused Lima")
        #expect(try restored.activateVerifiedInstall(version: "4.0.0", build: "4000000") == nil)

        let again = LimaReleaseHistoryStore(fileURL: url)
        #expect(again.installed.count == 1)
        #expect(again.notesForInstalled(version: "4.0.0", build: "4000000") != nil)
    }

    @Test
    func wrongBuildAndDamagedHistoryNeverBecomeInstalled() throws {
        let url = try temporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let archive = LimaReleaseHistoryStore(fileURL: url)
        try archive.stageAvailable(manifest(build: "4000001"))
        #expect(try archive.activateVerifiedInstall(version: "4.0.0", build: "4000000") == nil)
        #expect(archive.installed.isEmpty)

        try Data("{invalid".utf8).write(to: url, options: .atomic)
        let damaged = LimaReleaseHistoryStore(fileURL: url)
        #expect(damaged.storageError != nil)
        do {
            try damaged.stageAvailable(manifest())
            Issue.record("Damaged release history must not be overwritten")
        } catch {
            #expect(error is LimaReleaseHistoryError)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{invalid")
    }

    @Test
    func structuredManifestIsBoundToVersionAndRegisteredRoutes() throws {
        let encoded = try JSONEncoder().encode(manifest())
        let json = String(decoding: encoded, as: UTF8.self)
        let body = "```lima-release\n\(json)\n```"
        let parsed = LimaReleaseNotesParser.fromGitHubRelease(
            version: "4.0.0", name: nil, body: body,
            url: URL(string: "https://github.com/hosfeldli/ray-placement/releases/tag/v4.0.0")
        )
        #expect(parsed.importance == .major)
        #expect(parsed.requiresOnboarding)
        #expect(parsed.highlights.first?.destination == .audioSettings)

        let wrongVersion = LimaReleaseNotesParser.fromGitHubRelease(
            version: "4.0.1", name: nil, body: body, url: nil
        )
        #expect(!wrongVersion.requiresOnboarding)

        let unknownRoute = LimaReleaseNotesParser.fromGitHubRelease(
            version: "4.0.0", name: nil,
            body: body.replacingOccurrences(of: "settings.audio", with: "settings.run-script"),
            url: nil
        )
        #expect(!unknownRoute.requiresOnboarding)
    }

    @Test
    func parserStripsExternalLinksAndRejectsUnregisteredMetadata() {
        let parsed = LimaReleaseNotesParser.fromGitHubRelease(
            version: "4.0.0",
            name: "Lima 4.0.0",
            body: "A focused release.\n## New Features\n- Select [audio](javascript:alert(1)) via https://example.com.\n<img src='https://example.com/x'>\n## Removed Features\n- Dedicated Workflows.",
            url: URL(string: "javascript:alert(1)")
        )
        #expect(parsed.isValid)
        #expect(parsed.releaseURL == nil)
        #expect(parsed.sections.count == 2)
        #expect(parsed.sections[0].category == .newFeatures)
        #expect(!parsed.sections[0].markdown.contains("javascript:"))
        #expect(!parsed.sections[0].markdown.contains("https://"))
        #expect(!parsed.sections[0].markdown.contains("<img"))
        #expect(parsed.requiresOnboarding == false)

        let invalid = manifest(version: "not-a-version")
        #expect(!invalid.isValid)
    }
}
