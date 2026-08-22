import Foundation
import RayPlacementCore
import RayPlacementWriting
import ServiceManagement

enum ApplicationPaths {
    static let applicationSupport: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("RayPlacement", isDirectory: true)
    }()

    static let extensions = applicationSupport.appendingPathComponent("Extensions", isDirectory: true)
    static let clipboardHistory = applicationSupport.appendingPathComponent("clipboard-history.json")
    static let harperDictionary = applicationSupport.appendingPathComponent("harper-dictionary.txt")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let activationShortcut = "activationShortcut"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardLimit = "clipboardLimit"
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
        static let extensionShortcutOverrides = "extensionShortcutOverrides"
        static let writingProvider = "writingProvider"
    }

    private let defaults = UserDefaults.standard
    private var isRestoringActivationShortcut = false

    @Published var activationShortcut: String {
        didSet {
            defaults.set(activationShortcut, forKey: Key.activationShortcut)
            if !isRestoringActivationShortcut {
                NotificationCenter.default.post(name: .rayPlacementShortcutChanged, object: nil)
            }
        }
    }

    @Published var clipboardEnabled: Bool {
        didSet {
            defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled)
            NotificationCenter.default.post(name: .rayPlacementClipboardSettingsChanged, object: nil)
        }
    }

    @Published var clipboardLimit: Int {
        didSet {
            clipboardLimit = min(max(clipboardLimit, 10), 500)
            defaults.set(clipboardLimit, forKey: Key.clipboardLimit)
            NotificationCenter.default.post(name: .rayPlacementClipboardSettingsChanged, object: nil)
        }
    }

    @Published var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Key.showInDock) }
    }

    @Published var writingProvider: WritingProvider {
        didSet { defaults.set(writingProvider.rawValue, forKey: Key.writingProvider) }
    }

    @Published private(set) var extensionShortcutOverrides: [String: String]

    @Published private(set) var launchAtLogin: Bool
    @Published var lastError: String?

    private init() {
        activationShortcut = defaults.string(forKey: Key.activationShortcut) ?? "option+space"
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? false
        let storedLimit = defaults.integer(forKey: Key.clipboardLimit)
        clipboardLimit = storedLimit == 0 ? 50 : storedLimit
        showInDock = defaults.bool(forKey: Key.showInDock)
        writingProvider = WritingProvider(rawValue: defaults.string(forKey: Key.writingProvider) ?? "") ?? .harper
        extensionShortcutOverrides = defaults.dictionary(forKey: Key.extensionShortcutOverrides) as? [String: String] ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    break
                case .requiresApproval:
                    SMAppService.openSystemSettingsLoginItems()
                    lastError = "Approve RayPlacement in System Settings → General → Login Items."
                    launchAtLogin = false
                    return
                default:
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            defaults.set(enabled, forKey: Key.launchAtLogin)
            lastError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            lastError = error.localizedDescription
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func restoreActivationShortcut(_ shortcut: String) {
        isRestoringActivationShortcut = true
        activationShortcut = shortcut
        isRestoringActivationShortcut = false
    }

    func effectiveShortcut(for loaded: LoadedExtensionCommand) -> String? {
        let identifier = commandIdentifier(for: loaded)
        if let override = extensionShortcutOverrides[identifier] {
            return override.isEmpty ? nil : override
        }
        return loaded.command.hotkey
    }

    func hasShortcutOverride(for loaded: LoadedExtensionCommand) -> Bool {
        extensionShortcutOverrides[commandIdentifier(for: loaded)] != nil
    }

    func setShortcut(_ shortcut: String?, for loaded: LoadedExtensionCommand) {
        extensionShortcutOverrides[commandIdentifier(for: loaded)] = shortcut ?? ""
        saveShortcutOverrides()
    }

    func resetShortcut(for loaded: LoadedExtensionCommand) {
        extensionShortcutOverrides.removeValue(forKey: commandIdentifier(for: loaded))
        saveShortcutOverrides()
    }

    private func commandIdentifier(for loaded: LoadedExtensionCommand) -> String {
        "\(loaded.extensionID).\(loaded.command.id)"
    }

    private func saveShortcutOverrides() {
        defaults.set(extensionShortcutOverrides, forKey: Key.extensionShortcutOverrides)
        NotificationCenter.default.post(name: .rayPlacementExtensionShortcutsChanged, object: nil)
    }
}
