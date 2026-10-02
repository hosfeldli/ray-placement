import Foundation
import RayPlacementCore

@MainActor
final class WorkspaceProfileStore: ObservableObject {
    static let shared = WorkspaceProfileStore()

    @Published private(set) var profiles: [WorkspaceProfile]
    @Published private(set) var activeProfileID: UUID? {
        didSet { LimaTestEnvironment.userDefaults.set(activeProfileID?.uuidString, forKey: Self.activeProfileKey) }
    }
    @Published private(set) var lastError: String?
    var onActivation: (() -> Void)?

    private static let activeProfileKey = "lima.workspace.activeProfileID"
    private let store = PrivateFileStore()
    private let url = ApplicationPaths.workspaceProfiles

    private init() {
        let loaded = store.loadJSON([WorkspaceProfile].self, from: url)
        if let profiles = loaded.value, !profiles.isEmpty {
            self.profiles = profiles
        } else {
            self.profiles = [WorkspaceProfile(name: "Default")]
        }
        let savedID = LimaTestEnvironment.userDefaults.string(forKey: Self.activeProfileKey).flatMap(UUID.init(uuidString:))
        self.activeProfileID = self.profiles.first(where: { $0.id == savedID })?.id ?? self.profiles.first?.id
        if loaded.result.state == .corrupt || loaded.result.state == .unreadable {
            lastError = "Workspace profiles could not be restored. A recovery copy was preserved."
        }
    }

    var activeProfile: WorkspaceProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    @discardableResult
    func create(name: String = "New Workspace") -> WorkspaceProfile {
        captureCurrentState()
        let profile = WorkspaceProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Workspace" : name,
            state: WorkspaceStateRegistry.shared.state
        )
        profiles.insert(profile, at: 0)
        activeProfileID = profile.id
        save()
        return profile
    }

    func activate(_ profile: WorkspaceProfile) {
        guard profiles.contains(where: { $0.id == profile.id }), activeProfileID != profile.id else { return }
        captureCurrentState()
        activeProfileID = profile.id
        restoreActiveState()
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
        let wasActive = activeProfileID == profile.id
        profiles.removeAll { $0.id == profile.id }
        if wasActive {
            activeProfileID = profiles.first?.id
            restoreActiveState()
        }
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
        // Legacy terminal session IDs remain in WorkspaceState for
        // backwards-compatible decoding, but the terminal is now one shell.
        WorkspaceStateRegistry.shared.update { state in state = profile.state }
        onActivation?()
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
