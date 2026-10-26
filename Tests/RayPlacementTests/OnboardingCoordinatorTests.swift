import Foundation
import Testing
@testable import RayPlacement

@MainActor
struct OnboardingCoordinatorTests {
    private func fixture() -> LimaReleaseManifest {
        LimaReleaseManifest(
            version: "4.0.0",
            build: "4000000",
            channel: "stable",
            importance: .major,
            title: "A more focused Lima",
            summary: "Native audio and a simpler workspace.",
            highlights: [],
            sections: [],
            requiresOnboarding: true,
            onboardingID: "major-release-introduction",
            technicalDetails: nil,
            releaseURL: nil
        )
    }

    private func temporaryStateURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lima-OnboardingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("onboarding-state.json")
    }

    @Test
    func shownTourDoesNotReopenAfterDismissalOrCrash() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = fixture()
        let coordinator = OnboardingCoordinator(fileURL: url)
        #expect(coordinator.startIfNeeded(fixture))
        #expect(coordinator.isActive)
        coordinator.next()
        #expect(coordinator.step == .audio)

        // A launch during an unfinished tour must not repeatedly force it open.
        let afterCrash = OnboardingCoordinator(fileURL: url)
        #expect(!afterCrash.startIfNeeded(fixture))
        #expect(!afterCrash.isActive)
        #expect(afterCrash.progressFor(version: "4.0.0", build: "4000000",
                                       onboardingID: "major-release-introduction")?.lastCompletedStep == 0)

        coordinator.dismiss()
        let afterDismissal = OnboardingCoordinator(fileURL: url)
        #expect(!afterDismissal.startIfNeeded(fixture))
        #expect(afterDismissal.progressFor(version: "4.0.0", build: "4000000",
                                           onboardingID: "major-release-introduction")?.skipped == true)
        #expect(afterDismissal.replay(fixture))
        #expect(afterDismissal.step == .welcome)
        afterDismissal.complete()
        #expect(!afterDismissal.isActive)
        #expect(OnboardingCoordinator(fileURL: url).progressFor(
            version: "4.0.0", build: "4000000", onboardingID: "major-release-introduction"
        )?.completed == true)
    }

    @Test
    func unavailableOrDamagedStateNeverAutoStarts() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var noBuild = fixture()
        noBuild.build = nil
        let coordinator = OnboardingCoordinator(fileURL: url)
        #expect(!coordinator.startIfNeeded(noBuild))
        #expect(!coordinator.isActive)

        try Data("{bad".utf8).write(to: url)
        let damaged = OnboardingCoordinator(fileURL: url)
        #expect(damaged.storageError != nil)
        #expect(!damaged.startIfNeeded(fixture()))
        #expect(try String(contentsOf: url, encoding: .utf8) == "{bad")
    }
}
