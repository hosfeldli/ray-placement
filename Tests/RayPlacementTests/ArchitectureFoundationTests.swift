import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func taskRegistryFinishesOnlyMetadataAndInvokesExplicitCancellation() {
    let registry = TaskRegistry()
    var cancellationCount = 0
    let taskID = registry.begin(
        kind: .aiGeneration,
        title: "AI is working",
        detail: "Preparing a response",
        isCancellable: true,
        onCancel: { cancellationCount += 1 }
    )

    registry.update(taskID, title: "AI is reading", detail: "Reading sources", progress: 0.4)
    #expect(registry.activeTasks.first?.title == "AI is reading")
    #expect(registry.activeTasks.first?.progress == 0.4)

    registry.cancel(taskID)
    #expect(cancellationCount == 1)
    #expect(registry.activeTasks.isEmpty)
    #expect(registry.recentTasks.first?.state == .cancelled)
    #expect(registry.recentTasks.first?.detail == "Stopped by user")
}

@Test @MainActor func crashRecoveryStoresOnlyRecoverableUIIdentifiers() {
    let suite = "dev.liam.lima.tests.recovery.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = CrashRecoveryStore(defaults: defaults)
    store.beginLaunch()
    store.update {
        $0.activeSurface = LimaSurfaceID.workspace.rawValue
        $0.activeWorkspaceModule = LimaWorkspaceModule.ai.rawValue
        $0.selectedNoteID = UUID()
        $0.selectedConversationID = UUID()
        $0.formatterWasOpen = true
    }

    let restarted = CrashRecoveryStore(defaults: defaults)
    restarted.beginLaunch()
    #expect(restarted.pendingRestoration?.activeSurface == "workspace")
    #expect(restarted.pendingRestoration?.activeWorkspaceModule == "ai")
    #expect(restarted.pendingRestoration?.formatterWasOpen == true)

    restarted.markCleanShutdown()
    let cleanLaunch = CrashRecoveryStore(defaults: defaults)
    cleanLaunch.beginLaunch()
    #expect(cleanLaunch.pendingRestoration == nil)
}

@Test func activityShelfSupportsSixStableAnchors() {
    #expect(HUDDockPosition.allCases.count == 6)
    #expect(HUDDockPosition.topLeft.isTop)
    #expect(HUDDockPosition.topCenter.isTop)
    #expect(HUDDockPosition.topRight.isTop)
    #expect(!HUDDockPosition.bottomLeft.isTop)
    #expect(!HUDDockPosition.bottomCenter.isTop)
    #expect(!HUDDockPosition.bottomRight.isTop)
}

@Test func emojiPhraseAliasesPrioritizeFaceWithTearsOfJoy() {
    for query in ["laugh crying", "crying laughing", "laugh tears", "tears laughing", "lol", "lmao"] {
        #expect(EmojiCatalog.search(query).first?.emoji == "😂")
    }
}

@Test @MainActor func escapePolicyIsNavigationNotCancellation() {
    let coordinator = LimaSurfaceCoordinator.shared
    #expect(coordinator.escapeAction(for: .launcher, canNavigateBack: true, hasSelection: false) == .navigateBack)
    #expect(coordinator.escapeAction(for: .launcher, canNavigateBack: false, hasSelection: false) == .dismissSurface)
    #expect(coordinator.escapeAction(for: .workspace, canNavigateBack: false, hasSelection: false) == .none)
}
