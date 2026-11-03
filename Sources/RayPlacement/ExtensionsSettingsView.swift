import SwiftUI

/// All extension entry points use the same library and lifecycle model.
struct ExtensionsSettingsView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var storeModel: ExtensionStoreModel
    let reloadExtensions: () -> Void
    var localOnly = false
    var body: some View {
        ExtensionLibraryView(viewModel: viewModel, catalog: storeModel,
            reloadExtensions: reloadExtensions, localOnly: localOnly)
    }
}
