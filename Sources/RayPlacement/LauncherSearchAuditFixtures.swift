#if DEBUG
import SwiftUI

@MainActor
enum LauncherSearchAuditFixtures {
    static func view(scenario: String = "idle") -> some View {
        precondition(LimaTestEnvironment.isEnabled)
        let launcher = LauncherViewModel(clipboard: .shared, scanApplications: false)
        if scenario == "actions" { launcher.query = "notes"; launcher.openActionPanel(); launcher.moveActionPanelSelection(by: 1) }
        if scenario == "filtered" { launcher.query = "notes" }
        if scenario == "empty" { launcher.query = "zzzz_no_matching_command_zzzz" }
        if scenario == "selection" {
            launcher.setContextualSelection("Turn this project update into a short checklist. Keep each change reviewable.")
            launcher.query = "selection"
        }
        return LauncherView(
            viewModel: launcher, terminalModel: DeveloperTerminalModel(),
            aiChatModel: AIChatVisualFixtures.model(for: .empty),
            passwordGeneratorModel: PasswordGeneratorModel(),
            inlineExtensionSurfaceModel: InlineExtensionSurfaceModel(),
            formatterModel: FormatterWorkspaceModel(),
            extensionStoreModel: ExtensionStoreModel(onInstalled: {}),
            surfaceSessionController: LauncherSurfaceSessionController()
        )
    }
}
#endif
