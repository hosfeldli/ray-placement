import Combine
import Foundation

/// SettingsStore remains the persistence and migration façade. Structural
/// workspace views observe only this projection, not every preference.
@MainActor
final class WorkspaceLayoutStore: ObservableObject {
    static let shared = WorkspaceLayoutStore(settings: .shared)

    @Published private(set) var configuration: WorkspaceConfiguration
    private var subscription: AnyCancellable?

    init(settings: SettingsStore) {
        configuration = settings.workspaceConfiguration
        subscription = settings.$workspaceConfiguration
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] configuration in
                self?.configuration = configuration
            }
    }
}

struct LimaAppearanceSnapshot: Equatable {
    let glassStyle: AppGlassStyle
    let accent: AppAccentTheme
}

/// A single narrow appearance publication for structural glass. Changes to
/// AI, Terminal, Clipboard, and other unrelated preferences do not redraw it.
@MainActor
final class AppearancePreferences: ObservableObject {
    static let shared = AppearancePreferences(settings: .shared)

    @Published private(set) var snapshot: LimaAppearanceSnapshot
    private var subscription: AnyCancellable?

    init(settings: SettingsStore) {
        snapshot = LimaAppearanceSnapshot(glassStyle: settings.glassStyle, accent: settings.accentTheme)
        subscription = Publishers.CombineLatest(settings.$glassStyle, settings.$accentTheme)
            .map { LimaAppearanceSnapshot(glassStyle: $0, accent: $1) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] snapshot in
                self?.snapshot = snapshot
            }
    }
}
