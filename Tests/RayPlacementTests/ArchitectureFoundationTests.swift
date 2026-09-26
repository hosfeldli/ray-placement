import AppKit
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
        $0.workspaceWasOpen = true
        $0.workWasActive = true
        $0.selectedNoteID = UUID()
        $0.selectedConversationID = UUID()
        $0.formatterWasOpen = true
    }

    let restarted = CrashRecoveryStore(defaults: defaults)
    restarted.beginLaunch()
    #expect(restarted.pendingRestoration?.activeSurface == "workspace")
    #expect(restarted.pendingRestoration?.activeWorkspaceModule == "ai")
    #expect(restarted.pendingRestoration?.formatterWasOpen == true)
    #expect(restarted.pendingRestoration?.workspaceWasOpen == true)
    #expect(restarted.pendingRestoration?.workWasActive == true)

    restarted.markCleanShutdown()
    let cleanLaunch = CrashRecoveryStore(defaults: defaults)
    cleanLaunch.beginLaunch()
    #expect(cleanLaunch.pendingRestoration == nil)
}

@Test func crashRecoveryPlanRestoresOnlyValidSafeWorkspaceState() {
    let noteID = UUID()
    let aiConversationID = UUID()
    let snapshot = LimaRecoverySnapshot(
        activeSurface: LimaSurfaceID.workspace.rawValue,
        activeWorkspaceModule: LimaWorkspaceModule.ai.rawValue,
        selectedNoteID: noteID,
        selectedConversationID: aiConversationID,
        workspaceWasOpen: true,
        workWasActive: true
    )
    let plan = CrashRecoveryPlan.make(
        from: snapshot,
        availableNoteIDs: [noteID],
        availableAIConversationIDs: [aiConversationID]
    )

    #expect(plan?.module == .ai)
    #expect(plan?.selectedNoteID == noteID)
    #expect(plan?.selectedAIConversationID == aiConversationID)
    #expect(plan?.hadInterruptedWork == true)

    let missing = CrashRecoveryPlan.make(
        from: snapshot,
        availableNoteIDs: [],
        availableAIConversationIDs: []
    )
    #expect(missing?.selectedNoteID == nil)
    #expect(missing?.selectedAIConversationID == nil)

    let terminalSnapshot = LimaRecoverySnapshot(
        activeSurface: LimaSurfaceID.workspace.rawValue,
        activeWorkspaceModule: LimaWorkspaceModule.terminal.rawValue,
        workspaceWasOpen: true
    )
    #expect(CrashRecoveryPlan.make(
        from: terminalSnapshot,
        availableNoteIDs: [],
        availableAIConversationIDs: []
    )?.module == .notes)
}

@Test @MainActor func crashRecoveryDoesNotReopenHiddenWorkspaceAndMarksWorkInterrupted() {
    let hidden = LimaRecoverySnapshot(
        activeSurface: nil,
        formatterWasOpen: false,
        workspaceWasOpen: false
    )
    #expect(CrashRecoveryPlan.make(
        from: hidden,
        availableNoteIDs: [],
        availableAIConversationIDs: []
    ) == nil)

    let taskRegistry = TaskRegistry()
    taskRegistry.recordInterruptedWork()
    #expect(taskRegistry.activeTasks.isEmpty)
    #expect(taskRegistry.recentTasks.first?.kind == .interrupted)
    #expect(taskRegistry.recentTasks.first?.state == .failed)
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

@Test @MainActor func workspaceModuleEntryPointsReuseOneCoordinatedWindow() {
    let coordinator = LimaSurfaceCoordinator.shared
    let window = NSWindow(
        contentRect: NSRect(x: 20, y: 20, width: 900, height: 650),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: true
    )
    defer { coordinator.dismiss(.workspace) }

    for module in LimaWorkspaceModule.allCases {
        coordinator.present(
            .workspace,
            window: window,
            module: module,
            activate: false,
            remembersFrame: false
        )
        #expect(coordinator.window(for: .workspace) === window)
        #expect(coordinator.currentModule(for: .workspace) == module)
    }
}

@Test func commandCenterFiltersDisabledConflictingAndSearchableEntries() {
    func entry(
        id: String,
        title: String,
        kind: CommandCenterEntryKind,
        source: String = "Built-in",
        enabled: Bool = true,
        conflict: Bool = false,
        detail: String = "",
        model: String? = nil
    ) -> CommandCenterEntry {
        CommandCenterEntry(
            id: id,
            title: title,
            subtitle: detail,
            kind: kind,
            source: source,
            isEnabled: enabled,
            isFavorite: false,
            shortcut: "",
            isConflict: conflict,
            capabilities: [],
            presentation: nil,
            version: nil,
            detail: detail,
            risk: nil,
            availableToAI: nil,
            schema: nil,
            provider: nil,
            model: model,
            skills: [],
            tools: [],
            reasoning: nil
        )
    }

    let entries = [
        entry(id: "builtin.notes", title: "Notes", kind: .command, enabled: false, conflict: true),
        entry(id: "extension.review", title: "Review", kind: .extensionCommand, source: "Extension", detail: "Code review"),
        entry(id: "agent.research", title: "Research", kind: .agent, model: "Claude Sonnet")
    ]

    #expect(CommandCenterCatalog.visibleEntries(entries, filter: .disabled, query: "").map(\.id) == ["builtin.notes"])
    #expect(CommandCenterCatalog.visibleEntries(entries, filter: .conflicts, query: "").map(\.id) == ["builtin.notes"])
    #expect(CommandCenterCatalog.visibleEntries(entries, filter: .extensions, query: "").map(\.id) == ["extension.review"])
    #expect(CommandCenterCatalog.visibleEntries(entries, filter: .all, query: "research claude").map(\.id) == ["agent.research"])
}

@Test func runtimeDiagnosticsSummaryIsBoundedAndPrivacySafe() {
    let start = Date(timeIntervalSince1970: 1_000)
    func task(_ title: String, _ state: LimaTaskState) -> LimaTask {
        let date = start.addingTimeInterval(10)
        return LimaTask(
            id: UUID(),
            kind: .aiGeneration,
            title: title,
            detail: nil,
            state: state,
            progress: nil,
            startedAt: start,
            updatedAt: date,
            finishedAt: state.isActive ? nil : date,
            isCancellable: false
        )
    }
    func sample(_ operation: String, milliseconds: Int) -> LimaPerformanceSample {
        LimaPerformanceSample(
            id: UUID(),
            operation: operation,
            startedAt: start,
            duration: TimeInterval(milliseconds) / 1_000,
            succeeded: true,
            detail: nil
        )
    }

    let failures = (0..<8).map { task("AI request failure \($0)", .failed) }
    let cancelled = task("User stopped work", .cancelled)
    let active = task("AI is working", .running)
    let slowSamples = (0..<7).map { sample("slow operation \($0)", milliseconds: 1_200) }
    let snapshot = RuntimeDiagnosticsSnapshot.make(
        startedAt: start,
        now: start.addingTimeInterval(123),
        residentMemoryBytes: 4_194_304,
        activeTasks: [active],
        recentTasks: failures + [cancelled],
        performanceSamples: slowSamples + [sample("search", milliseconds: 450)],
        provider: .anthropic,
        providerCredentialConfigured: false,
        extensionIssueCount: -2,
        dictationEngine: .appleSpeech,
        dictationIsActive: true
    )

    #expect(snapshot.appUptime == 123)
    #expect(snapshot.residentMemoryBytes == 4_194_304)
    #expect(snapshot.activeTaskCount == 1)
    #expect(snapshot.recentFailures.map(\.id) == failures.prefix(5).map(\.id))
    #expect(snapshot.recentFailures.count == RuntimeDiagnosticsSnapshot.maximumRecentFailures)
    #expect(snapshot.recentSlowOperations.map(\.operation) == slowSamples.prefix(5).map(\.operation))
    #expect(snapshot.recentSlowOperations.count == RuntimeDiagnosticsSnapshot.maximumRecentSlowOperations)
    #expect(snapshot.providerStatus == "Credential not configured")
    #expect(snapshot.extensionIssueCount == 0)
    #expect(snapshot.dictationEngine == .appleSpeech)
    #expect(snapshot.dictationIsActive)
}
