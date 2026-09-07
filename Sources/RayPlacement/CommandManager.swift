import Foundation
import RayPlacementCore

struct ManagedCommandDescriptor: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
}

@MainActor
final class CommandManager: ObservableObject {
    static let shared = CommandManager()

    @Published private(set) var favoriteIDs: Set<String>
    @Published private(set) var profiles: [CommandProfile]
    @Published var activeProfileID: UUID?
    @Published private(set) var conflictMessages: [String] = []

    private let defaults = UserDefaults.standard
    private let favoritesKey = "commandManager.favoriteIDs"
    private let profilesKey = "commandManager.profiles"
    private let activeProfileKey = "commandManager.activeProfileID"

    private init() {
        favoriteIDs = Set(defaults.stringArray(forKey: favoritesKey) ?? [])
        if let data = defaults.data(forKey: profilesKey), let decoded = try? JSONDecoder().decode([CommandProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = [CommandProfile(name: "Default")]
        }
        activeProfileID = defaults.string(forKey: activeProfileKey).flatMap(UUID.init(uuidString:)) ?? profiles.first?.id
    }

    var activeProfile: CommandProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    func isEnabled(_ id: String) -> Bool {
        guard let profile = activeProfile else { return true }
        if profile.disabledCommandIDs.contains(id) { return false }
        return profile.enabledCommandIDs?.contains(id) ?? true
    }

    func isFavorite(_ id: String) -> Bool {
        activeProfile?.favoriteCommandIDs.contains(id) == true || favoriteIDs.contains(id)
    }

    func favoriteRank(_ id: String) -> Int {
        if let rank = activeProfile?.favoriteCommandOrder.firstIndex(of: id) { return rank }
        if let rank = activeProfile?.favoriteCommandIDs.sorted().firstIndex(of: id) { return rank }
        if let rank = favoriteIDs.sorted().firstIndex(of: id) { return rank }
        return Int.max
    }

    func toggleFavorite(_ id: String) {
        if var profile = activeProfile, let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            if profile.favoriteCommandIDs.contains(id) {
                profile.favoriteCommandIDs.remove(id)
                profile.favoriteCommandOrder.removeAll { $0 == id }
            } else {
                profile.favoriteCommandIDs.insert(id)
                profile.favoriteCommandOrder.append(id)
            }
            profiles[index] = profile
        } else if favoriteIDs.contains(id) {
            favoriteIDs.remove(id)
        } else {
            favoriteIDs.insert(id)
        }
        save()
        notifyChanged()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard var profile = activeProfile, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if enabled {
            profile.disabledCommandIDs.remove(id)
            if profile.enabledCommandIDs != nil { profile.enabledCommandIDs?.insert(id) }
        } else if profile.enabledCommandIDs == nil {
            profile.disabledCommandIDs.insert(id)
        } else {
            profile.enabledCommandIDs?.remove(id)
        }
        profiles[index] = profile
        save()
        notifyChanged()
    }

    func moveFavorite(_ id: String, by offset: Int) {
        guard var profile = activeProfile,
              let profileIndex = profiles.firstIndex(where: { $0.id == profile.id }),
              let currentIndex = profile.favoriteCommandOrder.firstIndex(of: id) else { return }
        let target = min(max(currentIndex + offset, 0), profile.favoriteCommandOrder.count - 1)
        guard target != currentIndex else { return }
        profile.favoriteCommandOrder.swapAt(currentIndex, target)
        profiles[profileIndex] = profile
        save()
        notifyChanged()
    }

    func renameProfile(_ profile: CommandProfile, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = clean
        save()
        notifyChanged()
    }

    func deleteProfile(_ profile: CommandProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = profiles.first?.id }
        save()
        notifyChanged()
    }

    func createProfile(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let profile = CommandProfile(name: clean)
        profiles.append(profile)
        activeProfileID = profile.id
        save()
        notifyChanged()
    }

    func activate(_ profile: CommandProfile) {
        activeProfileID = profile.id
        save()
        notifyChanged()
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: .rayPlacementCommandProfilesChanged, object: nil)
    }

    func validateShortcuts(_ commands: [LoadedExtensionCommand]) {
        let grouped = Dictionary(grouping: commands.compactMap { command -> (String, String)? in
            guard let shortcut = SettingsStore.shared.effectiveShortcut(for: command), !shortcut.isEmpty else { return nil }
            return (shortcut.lowercased(), "\(command.extensionName): \(command.command.title)")
        }, by: \.0)
        conflictMessages = grouped.compactMap { shortcut, values in
            values.count > 1 ? "\(shortcut) is assigned to \(values.map(\.1).joined(separator: ", "))" : nil
        }.sorted()
    }

    private func save() {
        defaults.set(Array(favoriteIDs).sorted(), forKey: favoritesKey)
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: profilesKey) }
        defaults.set(activeProfileID?.uuidString, forKey: activeProfileKey)
    }
}
