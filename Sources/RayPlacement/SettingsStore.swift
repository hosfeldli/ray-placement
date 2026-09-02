import Foundation
import RayPlacementCore
import ServiceManagement

enum AppInterfaceDensity: String, CaseIterable, Identifiable {
    case compact
    case balanced
    case comfortable

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .compact: return "More commands and data with tighter controls."
        case .balanced: return "A compact default with clear breathing room."
        case .comfortable: return "Larger targets and more spacious work areas."
        }
    }
    var launcherWidth: CGFloat {
        switch self { case .compact: return 664; case .balanced: return 704; case .comfortable: return 744 }
    }
    var launcherHeight: CGFloat {
        switch self { case .compact: return 426; case .balanced: return 466; case .comfortable: return 510 }
    }
    var resultRowHeight: CGFloat {
        switch self { case .compact: return 35; case .balanced: return 40; case .comfortable: return 46 }
    }
}

enum NotesVisualTheme: String, CaseIterable, Identifiable {
    case prism
    case graphite
    case midnight
    case aurora
    case ink

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum NotesFontStyle: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case monospaced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Editorial"
        case .monospaced: return "Mono"
        }
    }
}

enum NotesContentWidth: String, CaseIterable, Identifiable {
    case focused
    case wide
    case fluid

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var maximum: CGFloat? {
        switch self {
        case .focused: return 760
        case .wide: return 980
        case .fluid: return nil
        }
    }
}

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

    var dictationMaximumDuration: TimeInterval {
        // Performance controls CPU use, not how much of a meeting may be saved.
        MeetingDictationPlan.maximumDuration
    }

    var dictationTranscriptionTimeout: TimeInterval {
        // Meeting audio is irreplaceable. Dictation remains cancelable in the
        // HUD, but it is never discarded because a model crossed a short timer.
        0
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

enum DictationEngine: String, CaseIterable, Identifiable {
    case localWhisper
    case appleSpeech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localWhisper: return "Local Whisper · Recommended"
        case .appleSpeech: return "Apple Speech"
        }
    }

    var detail: String {
        switch self {
        case .localWhisper:
            return "More reliable for meetings and distant speech. Adds local transcript windows while you keep recording and needs only Microphone access."
        case .appleSpeech:
            return "Uses macOS on-device recognition for the fastest live updates, with short local windows and no cloud transcription."
        }
    }
}

enum DictationComputeMode: String, CaseIterable, Identifiable {
    case automatic
    case metal
    case cpu

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic · Metal with CPU fallback"
        case .metal: return "Apple GPU · Metal"
        case .cpu: return "CPU only"
        }
    }
}

enum ApplicationPaths {
    static let applicationSupport: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let current = root.appendingPathComponent("Lima", isDirectory: true)
        let legacy = root.appendingPathComponent("RayPlacement", isDirectory: true)
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            do {
                try FileManager.default.moveItem(at: legacy, to: current)
            } catch {
                // Never strand an existing workspace because a migration could
                // not complete (for example, a transient file lock).
                return legacy
            }
        }
        return current
    }()

    static let extensions = applicationSupport.appendingPathComponent("Extensions", isDirectory: true)
    static let clipboardHistory = applicationSupport.appendingPathComponent("clipboard-history.json")
    static let harperDictionary = applicationSupport.appendingPathComponent("harper-dictionary.txt")
    static let notes = applicationSupport.appendingPathComponent("notes.json")
    static let dictationScratch = applicationSupport.appendingPathComponent("Dictation", isDirectory: true)
    static let failedDictations = applicationSupport.appendingPathComponent("Failed Dictations", isDirectory: true)
    static let updates = applicationSupport.appendingPathComponent("Updates", isDirectory: true)
    static let usage = applicationSupport.appendingPathComponent("Usage", isDirectory: true)
    static let usageLog = usage.appendingPathComponent("usage-log.json")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationScratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failedDictations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let activationShortcut = "activationShortcut"
        static let activationHotkeyEnabled = "activationHotkeyEnabled"
        static let notesShortcut = "notesShortcut"
        static let notesHotkeyEnabled = "notesHotkeyEnabled"
        static let quickNoteShortcut = "quickNoteShortcut"
        static let quickNoteHotkeyEnabled = "quickNoteHotkeyEnabled"
        static let dictationShortcut = "dictationShortcut"
        static let dictationHotkeyEnabled = "dictationHotkeyEnabled"
        static let notesDockLeftShortcut = "notesDockLeftShortcut"
        static let notesDockLeftHotkeyEnabled = "notesDockLeftHotkeyEnabled"
        static let notesDockRightShortcut = "notesDockRightShortcut"
        static let notesDockRightHotkeyEnabled = "notesDockRightHotkeyEnabled"
        static let terminalShortcut = "terminalShortcut"
        static let terminalHotkeyEnabled = "terminalHotkeyEnabled"
        static let sqlShortcut = "sqlShortcut"
        static let sqlHotkeyEnabled = "sqlHotkeyEnabled"
        static let accessoryMouseBindings = "accessoryMouseBindings"
        static let accentTheme = "accentTheme"
        static let interfaceDensity = "interfaceDensity"
        static let notesVisualTheme = "notesVisualTheme"
        static let notesFontStyle = "notesFontStyle"
        static let notesFontSize = "notesFontSize"
        static let notesLineSpacing = "notesLineSpacing"
        static let notesContentWidth = "notesContentWidth"
        static let notesShowMetadata = "notesShowMetadata"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardLimit = "clipboardLimit"
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
        static let extensionShortcutOverrides = "extensionShortcutOverrides"
        static let extensionEnabledOverrides = "extensionEnabledOverrides"
        static let extensionHotkeyEnabledOverrides = "extensionHotkeyEnabledOverrides"
        static let writingInstructions = "writingInstructions"
        static let writingPerformance = "writingPerformance"
        static let dictationPerformance = "dictationPerformance"
        static let dictationEngine = "dictationEngine"
        static let dictationComputeMode = "dictationComputeMode"
        static let extensionPerformance = "extensionPerformance"
        static let dynamicPerformance = "dynamicPerformance"
    }

    private let defaults = UserDefaults.standard
    private var isRestoringActivationShortcut = false
    private var isRestoringActionShortcut = false

    static let defaultWritingInstructions = "RayPlacement\nVS Code\nPostman\nEDI"

    @Published var activationShortcut: String {
        didSet {
            defaults.set(activationShortcut, forKey: Key.activationShortcut)
            if !isRestoringActivationShortcut {
                NotificationCenter.default.post(name: .rayPlacementShortcutChanged, object: nil)
            }
        }
    }

    @Published var activationHotkeyEnabled: Bool {
        didSet {
            defaults.set(activationHotkeyEnabled, forKey: Key.activationHotkeyEnabled)
            NotificationCenter.default.post(name: .rayPlacementShortcutChanged, object: nil)
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

    @Published var notesHotkeyEnabled: Bool {
        didSet {
            defaults.set(notesHotkeyEnabled, forKey: Key.notesHotkeyEnabled)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
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

    @Published var quickNoteHotkeyEnabled: Bool {
        didSet {
            defaults.set(quickNoteHotkeyEnabled, forKey: Key.quickNoteHotkeyEnabled)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
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

    @Published var dictationHotkeyEnabled: Bool {
        didSet {
            defaults.set(dictationHotkeyEnabled, forKey: Key.dictationHotkeyEnabled)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
        }
    }

    @Published var notesDockLeftShortcut: String {
        didSet {
            defaults.set(notesDockLeftShortcut, forKey: Key.notesDockLeftShortcut)
            if !isRestoringActionShortcut { NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil) }
        }
    }

    @Published var notesDockLeftHotkeyEnabled: Bool {
        didSet {
            defaults.set(notesDockLeftHotkeyEnabled, forKey: Key.notesDockLeftHotkeyEnabled)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
        }
    }

    @Published var notesDockRightShortcut: String {
        didSet {
            defaults.set(notesDockRightShortcut, forKey: Key.notesDockRightShortcut)
            if !isRestoringActionShortcut { NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil) }
        }
    }

    @Published var notesDockRightHotkeyEnabled: Bool {
        didSet {
            defaults.set(notesDockRightHotkeyEnabled, forKey: Key.notesDockRightHotkeyEnabled)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
        }
    }

    @Published var terminalShortcut: String {
        didSet { defaults.set(terminalShortcut, forKey: Key.terminalShortcut); if !isRestoringActionShortcut { NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil) } }
    }

    @Published var terminalHotkeyEnabled: Bool {
        didSet { defaults.set(terminalHotkeyEnabled, forKey: Key.terminalHotkeyEnabled); NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil) }
    }

    @Published var sqlShortcut: String {
        didSet { defaults.set(sqlShortcut, forKey: Key.sqlShortcut); if !isRestoringActionShortcut { NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil) } }
    }

    @Published var sqlHotkeyEnabled: Bool {
        didSet { defaults.set(sqlHotkeyEnabled, forKey: Key.sqlHotkeyEnabled); NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil) }
    }

    @Published var accessoryMouseBindings: [String: String] {
        didSet {
            defaults.set(accessoryMouseBindings, forKey: Key.accessoryMouseBindings)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
        }
    }

    @Published var accentTheme: AppAccentTheme {
        didSet {
            defaults.set(accentTheme.rawValue, forKey: Key.accentTheme)
            NotificationCenter.default.post(name: .rayPlacementAccentChanged, object: nil)
        }
    }

    @Published var interfaceDensity: AppInterfaceDensity {
        didSet { defaults.set(interfaceDensity.rawValue, forKey: Key.interfaceDensity) }
    }

    @Published var notesVisualTheme: NotesVisualTheme {
        didSet { defaults.set(notesVisualTheme.rawValue, forKey: Key.notesVisualTheme) }
    }

    @Published var notesFontStyle: NotesFontStyle {
        didSet { defaults.set(notesFontStyle.rawValue, forKey: Key.notesFontStyle) }
    }

    @Published var notesFontSize: Double {
        didSet {
            notesFontSize = min(max(notesFontSize, 13), 24)
            defaults.set(notesFontSize, forKey: Key.notesFontSize)
        }
    }

    @Published var notesLineSpacing: Double {
        didSet {
            notesLineSpacing = min(max(notesLineSpacing, 1), 12)
            defaults.set(notesLineSpacing, forKey: Key.notesLineSpacing)
        }
    }

    @Published var notesContentWidth: NotesContentWidth {
        didSet { defaults.set(notesContentWidth.rawValue, forKey: Key.notesContentWidth) }
    }

    @Published var notesShowMetadata: Bool {
        didSet { defaults.set(notesShowMetadata, forKey: Key.notesShowMetadata) }
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

    @Published var dictationEngine: DictationEngine {
        didSet { defaults.set(dictationEngine.rawValue, forKey: Key.dictationEngine) }
    }

    @Published var dictationComputeMode: DictationComputeMode {
        didSet { defaults.set(dictationComputeMode.rawValue, forKey: Key.dictationComputeMode) }
    }

    @Published var extensionPerformance: PerformanceScale {
        didSet { defaults.set(extensionPerformance.rawValue, forKey: Key.extensionPerformance) }
    }

    @Published var dynamicPerformance: Bool {
        didSet { defaults.set(dynamicPerformance, forKey: Key.dynamicPerformance) }
    }

    @Published private(set) var extensionShortcutOverrides: [String: String]
    @Published private(set) var extensionEnabledOverrides: [String: Bool]
    @Published private(set) var extensionHotkeyEnabledOverrides: [String: Bool]

    @Published private(set) var launchAtLogin: Bool
    @Published var lastError: String?

    private init() {
        activationShortcut = defaults.string(forKey: Key.activationShortcut) ?? "option+space"
        activationHotkeyEnabled = defaults.object(forKey: Key.activationHotkeyEnabled) as? Bool ?? true
        notesShortcut = defaults.string(forKey: Key.notesShortcut) ?? "command+shift+n"
        notesHotkeyEnabled = defaults.object(forKey: Key.notesHotkeyEnabled) as? Bool ?? true
        quickNoteShortcut = defaults.string(forKey: Key.quickNoteShortcut) ?? "command+option+n"
        quickNoteHotkeyEnabled = defaults.object(forKey: Key.quickNoteHotkeyEnabled) as? Bool ?? true
        dictationShortcut = defaults.string(forKey: Key.dictationShortcut) ?? "control+option+d"
        dictationHotkeyEnabled = defaults.object(forKey: Key.dictationHotkeyEnabled) as? Bool ?? true
        notesDockLeftShortcut = defaults.string(forKey: Key.notesDockLeftShortcut) ?? "command+option+left"
        notesDockLeftHotkeyEnabled = defaults.object(forKey: Key.notesDockLeftHotkeyEnabled) as? Bool ?? false
        notesDockRightShortcut = defaults.string(forKey: Key.notesDockRightShortcut) ?? "command+option+right"
        notesDockRightHotkeyEnabled = defaults.object(forKey: Key.notesDockRightHotkeyEnabled) as? Bool ?? false
        terminalShortcut = defaults.string(forKey: Key.terminalShortcut) ?? "control+option+t"
        terminalHotkeyEnabled = defaults.object(forKey: Key.terminalHotkeyEnabled) as? Bool ?? false
        sqlShortcut = defaults.string(forKey: Key.sqlShortcut) ?? "control+option+s"
        sqlHotkeyEnabled = defaults.object(forKey: Key.sqlHotkeyEnabled) as? Bool ?? false
        accessoryMouseBindings = defaults.dictionary(forKey: Key.accessoryMouseBindings) as? [String: String] ?? [:]
        accentTheme = AppAccentTheme(rawValue: defaults.string(forKey: Key.accentTheme) ?? "") ?? .violet
        interfaceDensity = AppInterfaceDensity(rawValue: defaults.string(forKey: Key.interfaceDensity) ?? "") ?? .balanced
        notesVisualTheme = NotesVisualTheme(rawValue: defaults.string(forKey: Key.notesVisualTheme) ?? "") ?? .prism
        notesFontStyle = NotesFontStyle(rawValue: defaults.string(forKey: Key.notesFontStyle) ?? "") ?? .system
        let storedNotesFontSize = defaults.double(forKey: Key.notesFontSize)
        notesFontSize = storedNotesFontSize == 0 ? 15.5 : storedNotesFontSize
        let storedNotesLineSpacing = defaults.double(forKey: Key.notesLineSpacing)
        notesLineSpacing = storedNotesLineSpacing == 0 ? 3.5 : storedNotesLineSpacing
        notesContentWidth = NotesContentWidth(rawValue: defaults.string(forKey: Key.notesContentWidth) ?? "") ?? .wide
        notesShowMetadata = defaults.object(forKey: Key.notesShowMetadata) as? Bool ?? true
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? false
        let storedLimit = defaults.integer(forKey: Key.clipboardLimit)
        clipboardLimit = storedLimit == 0 ? 50 : storedLimit
        // Lima is a regular Mac app now. Existing installs that never chose a
        // visibility preference gain a Dock icon automatically; an explicit
        // stored preference is still respected.
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? true
        writingInstructions = defaults.string(forKey: Key.writingInstructions) ?? Self.defaultWritingInstructions
        writingPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.writingPerformance) ?? "") ?? .eco
        dictationPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.dictationPerformance) ?? "") ?? .eco
        dictationEngine = DictationEngine(rawValue: defaults.string(forKey: Key.dictationEngine) ?? "") ?? .localWhisper
        dictationComputeMode = DictationComputeMode(rawValue: defaults.string(forKey: Key.dictationComputeMode) ?? "") ?? .automatic
        extensionPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.extensionPerformance) ?? "") ?? .eco
        dynamicPerformance = defaults.object(forKey: Key.dynamicPerformance) as? Bool ?? false
        extensionShortcutOverrides = defaults.dictionary(forKey: Key.extensionShortcutOverrides) as? [String: String] ?? [:]
        extensionEnabledOverrides = defaults.dictionary(forKey: Key.extensionEnabledOverrides) as? [String: Bool] ?? [:]
        extensionHotkeyEnabledOverrides = defaults.dictionary(forKey: Key.extensionHotkeyEnabledOverrides) as? [String: Bool] ?? [:]
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
                    lastError = "Approve Lima in System Settings → General → Login Items."
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

    func restoreNotesDockLeftShortcut(_ shortcut: String) {
        isRestoringActionShortcut = true
        notesDockLeftShortcut = shortcut
        isRestoringActionShortcut = false
    }

    func restoreNotesDockRightShortcut(_ shortcut: String) {
        isRestoringActionShortcut = true
        notesDockRightShortcut = shortcut
        isRestoringActionShortcut = false
    }

    func restoreTerminalShortcut(_ shortcut: String) { isRestoringActionShortcut = true; terminalShortcut = shortcut; isRestoringActionShortcut = false }
    func restoreSQLShortcut(_ shortcut: String) { isRestoringActionShortcut = true; sqlShortcut = shortcut; isRestoringActionShortcut = false }

    func accessoryMouseAction(for button: Int) -> AccessoryMouseAction {
        accessoryMouseBindings[String(button)].flatMap(AccessoryMouseAction.init(rawValue:)) ?? .none
    }

    func setAccessoryMouseAction(_ action: AccessoryMouseAction, for button: Int) {
        guard (3...8).contains(button) else { return }
        if action == .none { accessoryMouseBindings.removeValue(forKey: String(button)) }
        else { accessoryMouseBindings[String(button)] = action.rawValue }
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

    func isExtensionEnabled(_ extensionID: String) -> Bool {
        extensionEnabledOverrides[extensionID] ?? true
    }

    func setExtensionEnabled(_ enabled: Bool, extensionID: String) {
        extensionEnabledOverrides[extensionID] = enabled
        defaults.set(extensionEnabledOverrides, forKey: Key.extensionEnabledOverrides)
        notifyExtensionConfigurationChanged()
    }

    func isCommandEnabled(_ loaded: LoadedExtensionCommand) -> Bool {
        isExtensionEnabled(loaded.extensionID)
    }

    func isHotkeyEnabled(_ loaded: LoadedExtensionCommand) -> Bool {
        isExtensionEnabled(loaded.extensionID)
            && (extensionHotkeyEnabledOverrides[commandIdentifier(for: loaded)] ?? true)
    }

    func setHotkeyEnabled(_ enabled: Bool, for loaded: LoadedExtensionCommand) {
        extensionHotkeyEnabledOverrides[commandIdentifier(for: loaded)] = enabled
        defaults.set(extensionHotkeyEnabledOverrides, forKey: Key.extensionHotkeyEnabledOverrides)
        notifyExtensionConfigurationChanged()
    }

    private func commandIdentifier(for loaded: LoadedExtensionCommand) -> String {
        "\(loaded.extensionID).\(loaded.command.id)"
    }

    private func saveShortcutOverrides() {
        defaults.set(extensionShortcutOverrides, forKey: Key.extensionShortcutOverrides)
        notifyExtensionConfigurationChanged()
    }

    private func notifyExtensionConfigurationChanged() {
        NotificationCenter.default.post(name: .rayPlacementExtensionShortcutsChanged, object: nil)
    }
}
