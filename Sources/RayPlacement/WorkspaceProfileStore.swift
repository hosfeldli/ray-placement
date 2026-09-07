import Foundation
import RayPlacementCore

@MainActor
final class WorkspaceProfileStore: ObservableObject {
    static let shared = WorkspaceProfileStore()

    @Published private(set) var profiles: [WorkspaceProfile]
    @Published var activeProfileID: UUID?
    @Published private(set) var lastError: String?

    private let store = PrivateFileStore()
    private let url = ApplicationPaths.workspaceProfiles

    private init() {
        let loaded = store.loadJSON([WorkspaceProfile].self, from: url)
        if let profiles = loaded.value, !profiles.isEmpty {
            self.profiles = profiles
        } else {
            self.profiles = [WorkspaceProfile(name: "Default")]
        }
        self.activeProfileID = self.profiles.first?.id
        if loaded.result.state == .corrupt || loaded.result.state == .unreadable {
            lastError = "Workspace profiles could not be restored. A recovery copy was preserved."
        }
    }

    var activeProfile: WorkspaceProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    @discardableResult
    func create(name: String = "New Workspace") -> WorkspaceProfile {
        let profile = WorkspaceProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Workspace" : name)
        profiles.insert(profile, at: 0)
        activeProfileID = profile.id
        save()
        return profile
    }

    func activate(_ profile: WorkspaceProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        activeProfileID = profile.id
        save()
    }

    func rename(_ profile: WorkspaceProfile, name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        profiles[index].name = clean
        profiles[index].updatedAt = Date()
        save()
    }

    func toggleFavorite(_ profile: WorkspaceProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].favorite.toggle()
        profiles[index].updatedAt = Date()
        save()
    }

    func delete(_ profile: WorkspaceProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = profiles.first?.id }
        save()
    }

    func captureCurrentState() {
        guard let activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        profiles[index].state = WorkspaceStateRegistry.shared.state
        profiles[index].updatedAt = Date()
        save()
    }

    func restoreActiveState() {
        guard let profile = activeProfile else { return }
        WorkspaceStateRegistry.shared.update { state in state = profile.state }
        if let terminalID = profile.state.terminalSessionID {
            TerminalSessionStore.shared.select(terminalID)
        }
    }

    private func save() {
        do {
            try ApplicationPaths.prepare()
            try store.write(profiles, to: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
