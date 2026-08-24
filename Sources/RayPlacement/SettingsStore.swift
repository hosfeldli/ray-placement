import Foundation
import RayPlacementCore
import RayPlacementWriting
import ServiceManagement

enum PerformanceScale: String, CaseIterable, Identifiable {
    case eco
    case balanced
    case high
    case turbo
    case maximum
    case unbounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eco: return "Eco"
        case .balanced: return "Balanced"
        case .high: return "High"
        case .turbo: return "Turbo"
        case .maximum: return "Maximum"
        case .unbounded: return "Unbounded"
        }
    }

    var level: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 1
    }

    static func level(_ value: Int) -> PerformanceScale {
        allCases[min(max(value - 1, 0), allCases.count - 1)]
    }

    func capped(at ceiling: PerformanceScale) -> PerformanceScale {
        level <= ceiling.level ? self : ceiling
    }

    var threadLimit: Int {
        switch self {
        case .eco: return 1
        case .balanced: return 2
        case .high: return 4
        case .turbo: return min(6, max(1, ProcessInfo.processInfo.activeProcessorCount))
        case .maximum: return min(12, max(1, ProcessInfo.processInfo.activeProcessorCount))
        case .unbounded: return max(1, ProcessInfo.processInfo.activeProcessorCount)
        }
    }

    var qualityOfService: QualityOfService {
        switch self {
        case .eco: return .background
        case .balanced: return .utility
        case .high, .turbo, .maximum: return .userInitiated
        case .unbounded: return .userInteractive
        }
    }

    var dispatchQoS: DispatchQoS.QoSClass {
        switch self {
        case .eco: return .background
        case .balanced: return .utility
        case .high, .turbo, .maximum: return .userInitiated
        case .unbounded: return .userInteractive
        }
    }

    var writingTimeout: TimeInterval {
        switch self {
        case .eco: return 90
        case .balanced: return 120
        case .high: return 180
        case .turbo: return 300
        case .maximum: return 600
        case .unbounded: return 0
        }
    }

    var summaryTokenLimit: Int {
        switch self {
        case .eco: return 256
        case .balanced: return 384
        case .high: return 512
        case .turbo: return 768
        case .maximum: return 1_024
        case .unbounded: return 2_048
        }
    }

    var dictationMaximumDuration: TimeInterval {
        switch self {
        case .eco: return 15 * 60
        case .balanced: return 30 * 60
        case .high, .turbo, .maximum, .unbounded: return MeetingDictationPlan.maximumDuration
        }
    }

    var dictationTranscriptionTimeout: TimeInterval {
        switch self {
        case .eco: return 90
        case .balanced: return 120
        case .high: return 180
        case .turbo: return 300
        case .maximum: return 600
        case .unbounded: return 0
        }
    }

    var extensionTimeout: TimeInterval {
        switch self {
        case .eco: return 60
        case .balanced: return 180
        case .high: return 600
        case .turbo: return 1_200
        case .maximum: return 3_600
        case .unbounded: return 0
        }
    }

    var isUnbounded: Bool { self == .unbounded }

    func timeoutDescription(_ seconds: TimeInterval) -> String {
        seconds <= 0 ? "no timeout" : "\(Int(seconds))s timeout"
    }
}

enum ApplicationPaths {
    static let applicationSupport: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("RayPlacement", isDirectory: true)
    }()

    static let extensions = applicationSupport.appendingPathComponent("Extensions", isDirectory: true)
    static let clipboardHistory = applicationSupport.appendingPathComponent("clipboard-history.json")
    static let harperDictionary = applicationSupport.appendingPathComponent("harper-dictionary.txt")
    static let notes = applicationSupport.appendingPathComponent("notes.json")
    static let dictationScratch = applicationSupport.appendingPathComponent("Dictation", isDirectory: true)
    static let updates = applicationSupport.appendingPathComponent("Updates", isDirectory: true)
    static let models = applicationSupport.appendingPathComponent("Models", isDirectory: true)
    static let usage = applicationSupport.appendingPathComponent("Usage", isDirectory: true)
    static let usageLog = usage.appendingPathComponent("usage-log.json")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationScratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let activationShortcut = "activationShortcut"
        static let notesShortcut = "notesShortcut"
        static let quickNoteShortcut = "quickNoteShortcut"
        static let dictationShortcut = "dictationShortcut"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardLimit = "clipboardLimit"
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
        static let extensionShortcutOverrides = "extensionShortcutOverrides"
        static let writingProvider = "writingProvider"
        static let writingInstructions = "writingInstructions"
        static let writingPerformance = "writingPerformance"
        static let dictationPerformance = "dictationPerformance"
        static let extensionPerformance = "extensionPerformance"
        static let dynamicPerformance = "dynamicPerformance"
        static let writingModel = "writingModel"
        static let summaryModel = "summaryModel"
        static let formatterModel = "formatterModel"
    }

    private let defaults = UserDefaults.standard
    private var isRestoringActivationShortcut = false
    private var isRestoringActionShortcut = false

    static let defaultWritingInstructions = "Preserve names, product terms, acronyms, Markdown, and intentional capitalization. Use clear, concise, professional English."

    @Published var activationShortcut: String {
        didSet {
            defaults.set(activationShortcut, forKey: Key.activationShortcut)
            if !isRestoringActivationShortcut {
                NotificationCenter.default.post(name: .rayPlacementShortcutChanged, object: nil)
            }
        }
    }

    @Published var notesShortcut: String {
        didSet {
            defaults.set(notesShortcut, forKey: Key.notesShortcut)
            if !isRestoringActionShortcut {
                NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
            }
        }
    }

    @Published var quickNoteShortcut: String {
        didSet {
            defaults.set(quickNoteShortcut, forKey: Key.quickNoteShortcut)
            if !isRestoringActionShortcut {
                NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
            }
        }
    }

    @Published var dictationShortcut: String {
        didSet {
            defaults.set(dictationShortcut, forKey: Key.dictationShortcut)
            if !isRestoringActionShortcut {
                NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
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

    @Published var writingInstructions: String {
        didSet {
            if writingInstructions.count > 4_000 {
                writingInstructions = String(writingInstructions.prefix(4_000))
                return
            }
            defaults.set(writingInstructions, forKey: Key.writingInstructions)
        }
    }

    @Published var writingPerformance: PerformanceScale {
        didSet { defaults.set(writingPerformance.rawValue, forKey: Key.writingPerformance) }
    }

    @Published var dictationPerformance: PerformanceScale {
        didSet { defaults.set(dictationPerformance.rawValue, forKey: Key.dictationPerformance) }
    }

    @Published var extensionPerformance: PerformanceScale {
        didSet { defaults.set(extensionPerformance.rawValue, forKey: Key.extensionPerformance) }
    }

    @Published var dynamicPerformance: Bool {
        didSet { defaults.set(dynamicPerformance, forKey: Key.dynamicPerformance) }
    }

    @Published var writingModel: LocalModelID {
        didSet { defaults.set(writingModel.rawValue, forKey: Key.writingModel) }
    }

    @Published var summaryModel: LocalModelID {
        didSet { defaults.set(summaryModel.rawValue, forKey: Key.summaryModel) }
    }

    @Published var formatterModel: LocalModelID {
        didSet { defaults.set(formatterModel.rawValue, forKey: Key.formatterModel) }
    }

    @Published private(set) var extensionShortcutOverrides: [String: String]

    @Published private(set) var launchAtLogin: Bool
    @Published var lastError: String?

    private init() {
        activationShortcut = defaults.string(forKey: Key.activationShortcut) ?? "option+space"
        notesShortcut = defaults.string(forKey: Key.notesShortcut) ?? "command+shift+n"
        quickNoteShortcut = defaults.string(forKey: Key.quickNoteShortcut) ?? "command+option+n"
        dictationShortcut = defaults.string(forKey: Key.dictationShortcut) ?? "control+option+d"
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? false
        let storedLimit = defaults.integer(forKey: Key.clipboardLimit)
        clipboardLimit = storedLimit == 0 ? 50 : storedLimit
        showInDock = defaults.bool(forKey: Key.showInDock)
        writingProvider = .qwen3Deep
        writingInstructions = defaults.string(forKey: Key.writingInstructions) ?? Self.defaultWritingInstructions
        writingPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.writingPerformance) ?? "") ?? .eco
        dictationPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.dictationPerformance) ?? "") ?? .eco
        extensionPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.extensionPerformance) ?? "") ?? .eco
        dynamicPerformance = defaults.object(forKey: Key.dynamicPerformance) as? Bool ?? false
        writingModel = LocalModelID(rawValue: defaults.string(forKey: Key.writingModel) ?? "") ?? .qwen3Balanced
        summaryModel = LocalModelID(rawValue: defaults.string(forKey: Key.summaryModel) ?? "") ?? .qwen3Balanced
        formatterModel = LocalModelID(rawValue: defaults.string(forKey: Key.formatterModel) ?? "") ?? .qwen3Balanced
        extensionShortcutOverrides = defaults.dictionary(forKey: Key.extensionShortcutOverrides) as? [String: String] ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var runtimeWritingPerformance: PerformanceScale {
        resolvedPerformance(cappedAt: writingPerformance)
    }

    var runtimeDictationPerformance: PerformanceScale {
        resolvedPerformance(cappedAt: dictationPerformance)
    }

    var runtimeExtensionPerformance: PerformanceScale {
        resolvedPerformance(cappedAt: extensionPerformance)
    }

    var dynamicPerformanceDescription: String {
        guard dynamicPerformance else { return "Manual limits are active." }
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return "Beta Dynamic is using Eco because Low Power Mode is on." }
        switch process.thermalState {
        case .nominal:
            return "Beta Dynamic is using the fastest safe level beneath each slider cap."
        case .fair:
            return "Beta Dynamic reduced active work to Balanced because the Mac is warm."
        case .serious, .critical:
            return "Beta Dynamic reduced active work to Eco to protect system responsiveness."
        @unknown default:
            return "Beta Dynamic is using a conservative active level."
        }
    }

    func selectedModel(for task: LocalModelTask) -> LocalModelID {
        let selected: LocalModelID
        switch task {
        case .writing: selected = writingModel
        case .summary: selected = summaryModel
        case .formatter: selected = formatterModel
        }
        return LocalModelCatalog.isInstalled(selected) ? selected : .qwen3Balanced
    }

    private func resolvedPerformance(cappedAt cap: PerformanceScale) -> PerformanceScale {
        guard dynamicPerformance else { return cap }
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return PerformanceScale.eco.capped(at: cap) }
        let target: PerformanceScale
        switch process.thermalState {
        case .nominal:
            target = process.activeProcessorCount >= 8 ? .turbo : .high
        case .fair:
            target = .balanced
        case .serious, .critical:
            target = .eco
        @unknown default:
            target = .balanced
        }
        return target.capped(at: cap)
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

    func restoreNotesShortcut(_ shortcut: String) {
        isRestoringActionShortcut = true
        notesShortcut = shortcut
        isRestoringActionShortcut = false
    }

    func restoreQuickNoteShortcut(_ shortcut: String) {
        isRestoringActionShortcut = true
        quickNoteShortcut = shortcut
        isRestoringActionShortcut = false
    }

    func restoreDictationShortcut(_ shortcut: String) {
        isRestoringActionShortcut = true
        dictationShortcut = shortcut
        isRestoringActionShortcut = false
    }

    func resetWritingInstructions() {
        writingInstructions = Self.defaultWritingInstructions
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
