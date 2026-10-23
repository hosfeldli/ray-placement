import Foundation
import Testing
@testable import RayPlacement

@Test func projectResolverDistinguishesWorkIntentWithoutCreatingDirectories() {
    #expect(AIWorkIntent.classify("What does WKWebView do?") == .informational)
    #expect(AIWorkIntent.classify("Format this JSON") == .transient)
    #expect(AIWorkIntent.classify("Fix the Browser tabs in Lima") == .durableExistingWork)
    #expect(AIWorkIntent.classify("Build me a new habit tracker") == .durableNewWork)
    #expect(AIWorkIntent.classify("Research current component libraries") == .informational)
    #expect(AIWorkIntent.classify("Research libraries, then build a dashboard") == .durableNewWork)
    #expect(AIWorkIntent.classify("Research libraries,\nthen build a dashboard") == .durableNewWork)
    #expect(AIWorkIntent.classify("What is wrong with Lima? Then fix the tabs") == .durableExistingWork)
    #expect(AIWorkIntent.classify("Can you build a website?") == .durableNewWork)
    #expect(AIWorkIntent.classify("I need a website") == .durableNewWork)
    #expect(AIWorkIntent.classify("Could you explain my existing app?") == .informational)
    #expect(AIWorkIntent.classify("Review my Lima code") == .informational)
    #expect(AIWorkIntent.classify("Please run this command") == .transient)
}

@Test func projectResolverOpensUniqueExistingWorkFromFullTaskRequest() async {
    let lima = AIProject(name: "Lima", instructions: "macOS productivity application",
                         repository: AIRepositoryMetadata(remoteURL: "https://github.com/hosfeldli/ray-placement.git", branch: "main"),
                         detectedStack: ["Swift", "SwiftUI"])
    let unrelated = AIProject(name: "Recipe Planner")
    let result = await AIProjectResolver.shared.resolve(
        intent: .durableExistingWork,
        query: "Fix the Browser tabs in Lima",
        projects: [lima, unrelated]
    )
    guard case .existing(let id, let confidence) = result else {
        Issue.record("A distinctive Project name in a full task request should be a strong match.")
        return
    }
    #expect(id == lima.id)
    #expect(confidence >= 0.9)
}

@Test func projectResolverReturnsAbsentAndAmbiguousWithoutGuessing() async {
    let dashboard = AIProject(name: "Finance Dashboard")
    let versionTwo = AIProject(name: "Finance Dashboard v2")
    let recipe = await AIProjectResolver.shared.resolve(
        intent: .durableNewWork,
        query: "Build a recipe planning website",
        projects: [dashboard, versionTwo]
    )
    guard case .createNew = recipe else {
        Issue.record("Unrelated durable work should create a new Project.")
        return
    }
    let finance = await AIProjectResolver.shared.resolve(
        intent: .durableExistingWork,
        query: "Add budgeting charts to my finance dashboard",
        projects: [dashboard, versionTwo]
    )
    guard case .ambiguous(let candidates) = finance else {
        Issue.record("Similarly named Projects should require a user decision.")
        return
    }
    #expect(candidates.map(\.projectID).contains(dashboard.id))
    #expect(candidates.map(\.projectID).contains(versionTwo.id))
}

@Test func projectResolverKeepsArchivedInDiscoveryAndRemovedOutByDefault() async {
    let archived = AIProject(name: "Old Portfolio", lifecycle: .archived)
    let removed = AIRemovedProject(project: AIProject(name: "Removed Tracker"), removedAt: Date())
    let archivedResult = await AIProjectResolver.shared.resolve(
        intent: .durableExistingWork,
        query: "Update Old Portfolio",
        projects: [archived],
        removed: [removed]
    )
    guard case .archived(let id, _) = archivedResult else {
        Issue.record("Archived Projects should be found before creating replacements.")
        return
    }
    #expect(id == archived.id)
    let ordinary = await AIProjectResolver.shared.search(
        query: "Removed Tracker", projects: [archived], removed: [removed]
    )
    #expect(ordinary.isEmpty)
    let explicit = await AIProjectResolver.shared.search(
        query: "Removed Tracker", projects: [archived], removed: [removed],
        includeRemoved: true
    )
    #expect(explicit.first?.projectID == removed.id)
    #expect(explicit.first?.lifecycle == "removed")
    let explicitResolution = await AIProjectResolver.shared.resolve(
        intent: .durableExistingWork, query: "Removed Tracker", projects: [archived],
        removed: [removed], includeRemoved: true
    )
    guard case .removed(let removedID, _) = explicitResolution else {
        Issue.record("Explicit removed search should recommend recovery, not new Project creation.")
        return
    }
    #expect(removedID == removed.id)
}
