import Foundation
import Testing
@testable import RayPlacement

@Test @MainActor func actionRegistryShowsOnlyAvailableFileCapabilities() {
    let url = URL(fileURLWithPath: "/tmp/Lima-action-registry-fixture.txt")
    var capabilities = LimaActionRegistry.Capabilities()
    capabilities.canOpenInCode = false
    capabilities.canAttachFileToAI = false
    let basic = LimaActionRegistry.fileActions(for: url, capabilities: capabilities)
    #expect(basic.map(\.id) == ["open", "quick-look", "reveal", "copy-path", "terminal", "shelf", "note"])
    #expect(basic.filter { $0.role == .primary }.map(\.id) == ["open"])

    capabilities.canOpenInCode = true
    capabilities.canAttachFileToAI = true
    let expanded = LimaActionRegistry.fileActions(for: url, capabilities: capabilities)
    #expect(expanded.map(\.id).contains("code"))
    #expect(expanded.map(\.id).contains("describe-ai"))
    #expect(expanded.map(\.id).contains("ask-ai"))
    #expect(expanded.first?.id == "open")
}

@Test @MainActor func actionRegistryDoesNotAdvertiseOperationsOnStaleFiles() {
    let url = URL(fileURLWithPath: "/tmp/Lima-missing-action-registry-fixture.txt")
    var capabilities = LimaActionRegistry.Capabilities()
    capabilities.objectExists = false
    capabilities.canOpenInCode = true
    capabilities.canAttachFileToAI = true
    let actions = LimaActionRegistry.fileActions(for: url, capabilities: capabilities)
    #expect(actions.map(\.id) == ["copy-path"])
    #expect(actions.first?.role == .primary)
    if case .fileAction(let target, .copyPath) = actions.first?.action {
        #expect(target == url)
    } else {
        Issue.record("A stale file should only offer a working copy-path action.")
    }
}

@Test @MainActor func actionRegistryUsesApplicationStateWithoutLosingPrimaryAction() {
    let url = URL(fileURLWithPath: "/Applications/Lima.app")
    let item = LauncherItem(id: "application.lima", title: "Lima", subtitle: "",
                            icon: .application(url), keywords: [], action: .launchApplication(url))
    var capabilities = LimaActionRegistry.Capabilities()
    capabilities.runningApplicationPID = 123
    capabilities.isFavorite = true
    let running = LimaActionRegistry.actions(for: item, capabilities: capabilities)
    #expect(running.map(\.id) == ["open", "reveal", "copy-path", "hide", "quit", "force-quit", "favorite"])
    #expect(running.filter { $0.role == .primary }.map(\.id) == ["open"])
    #expect(running.first { $0.id == "favorite" }?.title == "Unpin from Top")
    if case .applicationOperation(let operation, let pid, _) = running.first(where: { $0.id == "quit" })?.action {
        #expect(operation == "quit")
        #expect(pid == 123)
    } else {
        Issue.record("Quit must target the selected running application.")
    }

    capabilities.objectExists = false
    capabilities.runningApplicationPID = nil
    let stale = LimaActionRegistry.actions(for: item, capabilities: capabilities)
    #expect(stale.map(\.id) == ["copy-path", "favorite"])
    #expect(stale.first?.role == .primary)
}

@Test @MainActor func actionRegistryKeepsGeneralContextAndAliasActionsOrdered() {
    let item = LauncherItem(id: "builtin.settings", title: "Settings", subtitle: "",
                            icon: .system("gear"), keywords: [], action: .system(.openSettings))
    var capabilities = LimaActionRegistry.Capabilities()
    capabilities.canEditAlias = true
    capabilities.contextActions = [
        LauncherItemAction(id: "use-with.test", title: "Use With Test", symbol: "circle",
                           shortcut: nil, role: .secondary, action: .copyText("context"))
    ]
    let actions = LimaActionRegistry.actions(for: item, capabilities: capabilities)
    #expect(actions.map(\.id) == ["run", "use-with.test", "add-alias", "favorite", "forget"])
    #expect(actions.filter { $0.role == .primary }.map(\.id) == ["run"])
}
