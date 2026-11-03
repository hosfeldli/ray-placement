#if DEBUG
import Foundation
import SwiftUI
import RayPlacementCore

@MainActor
enum ExtensionLibraryVisualFixtures {
    static func view(diagnostics: Bool) -> some View {
        precondition(LimaTestEnvironment.isEnabled)
        let root = LimaTestEnvironment.dataRoot!.appendingPathComponent("extension-audit-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try! ExtensionDeveloperKit.create(at: root.appendingPathComponent("text-tool"), id: "local.audit.text-tool", name: "Text Cleaner", template: .aiTool)
        _ = try! ExtensionDeveloperKit.create(at: root.appendingPathComponent("quick-link"), id: "local.audit.quick-link", name: "Team Dashboard", template: .link)
        _ = try! ExtensionDeveloperKit.create(at: root.appendingPathComponent("broken-command"), id: "local.audit.broken-command", name: "Project Summary", template: .script)
        try! FileManager.default.removeItem(at: root.appendingPathComponent("broken-command/bin/run"))
        let store = ExtensionLibraryStore(root: root)
        let selected = root.appendingPathComponent(diagnostics ? "broken-command/manifest.json" : "text-tool/manifest.json").path
        return ExtensionLibraryView(viewModel: LauncherViewModel(clipboard: ClipboardHistoryService(fixtures: []), scanApplications: false),
            catalog: ExtensionStoreModel(onInstalled: {}), reloadExtensions: {}, library: store, selectedID: selected, showDiagnostics: diagnostics)
    }
}
#endif
