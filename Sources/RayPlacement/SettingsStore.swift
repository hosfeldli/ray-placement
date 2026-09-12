import Foundation
import RayPlacementCore
import ServiceManagement

enum GrammarCorrectionMode: String, CaseIterable, Identifiable {
    case proofread
    case polish

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .proofread: return "Correct spelling, grammar, and punctuation while preserving your voice."
        case .polish: return "Make conservative clarity and flow improvements in addition to proofreading."
        }
    }
}

enum GrammarEngineMode: String, CaseIterable, Identifiable {
    case local
    case externalAPI

    var id: String { rawValue }
    var title: String { self == .local ? "Local" : "External API" }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

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
    static let dictationConversations = applicationSupport.appendingPathComponent("dictation-conversations.json")
    static let noteAssets = applicationSupport.appendingPathComponent("Note Assets", isDirectory: true)
    static let dictationScratch = applicationSupport.appendingPathComponent("Dictation", isDirectory: true)
    static let failedDictations = applicationSupport.appendingPathComponent("Failed Dictations", isDirectory: true)
    static let updates = applicationSupport.appendingPathComponent("Updates", isDirectory: true)
    static let usage = applicationSupport.appendingPathComponent("Usage", isDirectory: true)
    static let usageLog = usage.appendingPathComponent("usage-log.json")
    static let workspaceProfiles = applicationSupport.appendingPathComponent("workspace-profiles.json")
    static let contextShelf = applicationSupport.appendingPathComponent("context-shelf.json")
    static let grammarDebugDatabase = applicationSupport.appendingPathComponent("grammar-debug.sqlite")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupport.path)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationScratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failedDictations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: noteAssets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
    }
}

enum LauncherSurfaceTimeoutOption: String, CaseIterable, Identifiable {
    case never = "never"
    case fiveSeconds = "5"
    case tenSeconds = "10"
    case fifteenSeconds = "15"
    case thirtySeconds = "30"
    case oneMinute = "60"
    case twoMinutes = "120"
    case fiveMinutes = "300"

    var id: String { rawValue }
    var seconds: TimeInterval { Double(rawValue) ?? 0 }
    var title: String {
        switch self {
        case .never: return "Never"
        case .fiveSeconds: return "5 seconds"
        case .tenSeconds: return "10 seconds"
        case .fifteenSeconds: return "15 seconds"
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .twoMinutes: return "2 minutes"
        case .fiveMinutes: return "5 minutes"
        }
    }
}

enum MusicHUDPresentation: String, Codable, CaseIterable, Identifiable {
    case mini
    case compact
    case expanded
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum HUDDockPosition: String, Codable, CaseIterable, Identifiable {
    case bottomCenter
    case bottomLeft
    case bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
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
        static let contextShelfCaptureShortcut = "contextShelfCaptureShortcut"
        static let contextShelfCaptureHotkeyEnabled = "contextShelfCaptureHotkeyEnabled"
        static let accessoryMouseBindings = "accessoryMouseBindings"
        static let accentTheme = "accentTheme"
        static let contrastMode = "contrastMode"
        static let appearance = "appearance"
        static let interfaceDensity = "interfaceDensity"
        static let notesVisualTheme = "notesVisualTheme"
        static let notesFontStyle = "notesFontStyle"
        static let notesFontSize = "notesFontSize"
        static let notesLineSpacing = "notesLineSpacing"
        static let notesContentWidth = "notesContentWidth"
        static let notesShowMetadata = "notesShowMetadata"
        static let quickNoteOpacity = "quickNoteOpacity"
        static let quickNoteAutoHide = "quickNoteAutoHide"
        static let quickNotePerSpaceMemory = "quickNotePerSpaceMemory"
        static let quickNoteDisplayLocked = "quickNoteDisplayLocked"
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardLimit = "clipboardLimit"
        static let launchAtLogin = "launchAtLogin"
        static let showInDock = "showInDock"
        static let extensionShortcutOverrides = "extensionShortcutOverrides"
        static let extensionEnabledOverrides = "extensionEnabledOverrides"
        static let extensionPackEnabledOverrides = "extensionPackEnabledOverrides"
        static let extensionHotkeyEnabledOverrides = "extensionHotkeyEnabledOverrides"
        static let writingInstructions = "writingInstructions"
        static let writingPerformance = "writingPerformance"
        static let stealthGrammarEnabled = "stealthGrammarEnabled"
        static let stealthGrammarShortcut = "stealthGrammarShortcut"
        static let developerGrammarEnabled = "developerGrammarEnabled"
        static let grammarEngineMode = "grammarEngineMode"
        static let grammarCorrectionMode = "grammarCorrectionMode"
        static let grammarEnsembleStrategy = "grammarEnsembleStrategy"
        static let grammarJudgeOnDisagreement = "grammarJudgeOnDisagreement"
        static let grammarDebugStoreSourceText = "grammarDebugStoreSourceText"
        static let grammarDebugRetentionDays = "grammarDebugRetentionDays"
        static let grammarDebugMaximumRuns = "grammarDebugMaximumRuns"
        static let developerGrammarProvider = "developerGrammarProvider"
        static let developerGrammarModel = "developerGrammarModel"
        static let developerGrammarBaseURL = "developerGrammarBaseURL"
        static let grammarFallbackToLocal = "grammarFallbackToLocal"
        static let inlineGrammarCheckingEnabled = "inlineGrammarCheckingEnabled"
        static let dictationPerformance = "dictationPerformance"
        static let dictationEngine = "dictationEngine"
        static let dictationComputeMode = "dictationComputeMode"
        static let extensionPerformance = "extensionPerformance"
        static let dynamicPerformance = "dynamicPerformance"
        static let launcherSurfaceTimeout = "launcherSurfaceTimeout"
        static let terminalUsesLauncherTimeout = "terminalUsesLauncherTimeout"
        static let musicHUDPresentation = "musicHUDPresentation"
        static let musicShowArtwork = "musicShowArtwork"
        static let musicShowPlaybackControls = "musicShowPlaybackControls"
        static let musicShowProgress = "musicShowProgress"
        static let musicShowWhenPaused = "musicShowWhenPaused"
        static let musicExpandOnClick = "musicExpandOnClick"
        static let musicExpandedTimeout = "musicExpandedTimeout"
        static let hudDockPosition = "hudDockPosition"
    }

    private let defaults = UserDefaults.standard
    private var isRestoringActivationShortcut = false
    private var isRestoringActionShortcut = false

    static let defaultWritingInstructions = "Lima\nVS Code\nEDI"

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

    @Published var contextShelfCaptureShortcut: String {
        didSet {
            defaults.set(contextShelfCaptureShortcut, forKey: Key.contextShelfCaptureShortcut)
            if !isRestoringActionShortcut {
                NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
            }
        }
    }

    @Published var contextShelfCaptureHotkeyEnabled: Bool {
        didSet {
            defaults.set(contextShelfCaptureHotkeyEnabled, forKey: Key.contextShelfCaptureHotkeyEnabled)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
        }
    }

    @Published var terminalHotkeyEnabled: Bool {
        didSet { defaults.set(terminalHotkeyEnabled, forKey: Key.terminalHotkeyEnabled); NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil) }
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

    @Published var contrastMode: AppContrastMode {
        didSet {
            defaults.set(contrastMode.rawValue, forKey: Key.contrastMode)
            NotificationCenter.default.post(name: .rayPlacementAccentChanged, object: nil)
        }
    }

    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); NotificationCenter.default.post(name: .rayPlacementAppearanceChanged, object: nil); NotificationCenter.default.post(name: .rayPlacementNotesAppearanceChanged, object: nil) }
    }

    @Published var interfaceDensity: AppInterfaceDensity {
        didSet { defaults.set(interfaceDensity.rawValue, forKey: Key.interfaceDensity) }
    }

    @Published var notesVisualTheme: NotesVisualTheme {
        didSet { defaults.set(notesVisualTheme.rawValue, forKey: Key.notesVisualTheme); NotificationCenter.default.post(name: .rayPlacementNotesAppearanceChanged, object: nil) }
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

    @Published var quickNoteOpacity: Double {
        didSet {
            quickNoteOpacity = min(max(quickNoteOpacity, 0.35), 1)
            defaults.set(quickNoteOpacity, forKey: Key.quickNoteOpacity)
        }
    }

    @Published var quickNoteAutoHide: Bool {
        didSet { defaults.set(quickNoteAutoHide, forKey: Key.quickNoteAutoHide) }
    }

    @Published var quickNotePerSpaceMemory: Bool {
        didSet { defaults.set(quickNotePerSpaceMemory, forKey: Key.quickNotePerSpaceMemory) }
    }

    @Published var quickNoteDisplayLocked: Bool {
        didSet { defaults.set(quickNoteDisplayLocked, forKey: Key.quickNoteDisplayLocked) }
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

    @Published var stealthGrammarEnabled: Bool {
        didSet {
            defaults.set(stealthGrammarEnabled, forKey: Key.stealthGrammarEnabled)
            NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
        }
    }

    @Published var stealthGrammarShortcut: String {
        didSet {
            defaults.set(stealthGrammarShortcut, forKey: Key.stealthGrammarShortcut)
            if !isRestoringActionShortcut {
                NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
            }
        }
    }

    @Published var grammarCorrectionMode: GrammarCorrectionMode {
        didSet { defaults.set(grammarCorrectionMode.rawValue, forKey: Key.grammarCorrectionMode) }
    }

    @Published var grammarEnsembleStrategy: GrammarEnsembleStrategy {
        didSet { defaults.set(grammarEnsembleStrategy.rawValue, forKey: Key.grammarEnsembleStrategy) }
    }

    @Published var grammarJudgeOnDisagreement: Bool {
        didSet { defaults.set(grammarJudgeOnDisagreement, forKey: Key.grammarJudgeOnDisagreement) }
    }

    @Published var grammarDebugStoreSourceText: Bool {
        didSet { defaults.set(grammarDebugStoreSourceText, forKey: Key.grammarDebugStoreSourceText) }
    }

    @Published var grammarDebugRetentionDays: Int {
        didSet { grammarDebugRetentionDays = min(max(grammarDebugRetentionDays, 1), 3650); defaults.set(grammarDebugRetentionDays, forKey: Key.grammarDebugRetentionDays) }
    }

    @Published var grammarDebugMaximumRuns: Int {
        didSet { grammarDebugMaximumRuns = min(max(grammarDebugMaximumRuns, 10), 100_000); defaults.set(grammarDebugMaximumRuns, forKey: Key.grammarDebugMaximumRuns) }
    }

    @Published var grammarEngineMode: GrammarEngineMode {
        didSet {
            defaults.set(grammarEngineMode.rawValue, forKey: Key.grammarEngineMode)
            // Keep the legacy key synchronized for older settings exporters.
            defaults.set(grammarEngineMode == .externalAPI, forKey: Key.developerGrammarEnabled)
        }
    }

    // Compatibility aliases for older callers and imported settings.
    var developerGrammarEnabled: Bool {
        get { grammarEngineMode == .externalAPI }
        set { grammarEngineMode = newValue ? .externalAPI : .local }
    }

    @Published var developerGrammarProvider: DeveloperGrammarProvider {
        didSet {
            defaults.set(developerGrammarProvider.rawValue, forKey: Key.developerGrammarProvider)
        }
    }

    @Published var developerGrammarModel: String {
        didSet { defaults.set(developerGrammarModel, forKey: Key.developerGrammarModel) }
    }

    @Published var developerGrammarBaseURL: String {
        didSet { defaults.set(developerGrammarBaseURL, forKey: Key.developerGrammarBaseURL) }
    }

    // Retained as an import/export compatibility boundary only. External
    // failures are never redirected to the local engine.
    var grammarFallbackToLocal: Bool {
        get { false }
        set { defaults.set(false, forKey: Key.grammarFallbackToLocal) }
    }

    @Published var inlineGrammarCheckingEnabled: Bool {
        didSet { defaults.set(inlineGrammarCheckingEnabled, forKey: Key.inlineGrammarCheckingEnabled) }
    }

    // User-facing aliases. The legacy developerGrammar names remain the
    // persistence and migration boundary for existing installations.
    var grammarEngineEnhanced: Bool {
        get { grammarEngineMode == .externalAPI }
        set { grammarEngineMode = newValue ? .externalAPI : .local }
    }

    var enhancedGrammarAPIKeyStored: Bool {
        !developerGrammarAPIKey.isEmpty
    }

    func selectDeveloperGrammarProvider(_ provider: DeveloperGrammarProvider) {
        let previousProvider = developerGrammarProvider
        let previousModel = developerGrammarModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousBaseURL = developerGrammarBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        developerGrammarProvider = provider

        // Preserve custom values when the user deliberately entered them, but
        // make provider switching immediately usable for preset selections.
        let wasPreset = previousProvider.modelOptions.contains { $0.id == previousModel }
        if previousModel.isEmpty || wasPreset {
            developerGrammarModel = provider.defaultModel
        }
        if previousBaseURL.isEmpty || previousBaseURL == previousProvider.defaultBaseURL {
            developerGrammarBaseURL = provider.defaultBaseURL
        }
    }

    var developerGrammarAPIKey: String {
        DeveloperGrammarKeychain.value(for: developerGrammarProvider)
    }

    var developerGrammarConfigurationForModelDiscovery: DeveloperGrammarConfiguration? {
        let key = developerGrammarAPIKey
        let baseURL = developerGrammarBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !baseURL.isEmpty else { return nil }
        return DeveloperGrammarConfiguration(
            provider: developerGrammarProvider,
            apiKey: key,
            model: developerGrammarModel.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL
        )
    }

    var developerGrammarConfigurationForTesting: DeveloperGrammarConfiguration? {
        let key = developerGrammarAPIKey
        let model = developerGrammarModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = developerGrammarBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty, !baseURL.isEmpty else { return nil }
        return DeveloperGrammarConfiguration(
            provider: developerGrammarProvider,
            apiKey: key,
            model: model,
            baseURL: baseURL
        )
    }

    func saveDeveloperGrammarAPIKey(_ value: String) throws {
        try DeveloperGrammarKeychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: developerGrammarProvider)
        objectWillChange.send()
    }

    var developerGrammarConfiguration: DeveloperGrammarConfiguration? {
        guard grammarEngineMode == .externalAPI else { return nil }
        return developerGrammarConfigurationForTesting
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

    @Published var launcherSurfaceTimeout: TimeInterval {
        didSet { defaults.set(launcherSurfaceTimeout, forKey: Key.launcherSurfaceTimeout) }
    }

    @Published var terminalUsesLauncherTimeout: Bool {
        didSet { defaults.set(terminalUsesLauncherTimeout, forKey: Key.terminalUsesLauncherTimeout) }
    }

    @Published var musicHUDPresentation: MusicHUDPresentation {
        didSet { defaults.set(musicHUDPresentation.rawValue, forKey: Key.musicHUDPresentation) }
    }

    @Published var musicShowArtwork: Bool {
        didSet { defaults.set(musicShowArtwork, forKey: Key.musicShowArtwork) }
    }

    @Published var musicShowPlaybackControls: Bool {
        didSet { defaults.set(musicShowPlaybackControls, forKey: Key.musicShowPlaybackControls) }
    }

    @Published var musicShowProgress: Bool {
        didSet { defaults.set(musicShowProgress, forKey: Key.musicShowProgress) }
    }

    @Published var musicShowWhenPaused: Bool {
        didSet { defaults.set(musicShowWhenPaused, forKey: Key.musicShowWhenPaused) }
    }

    @Published var musicExpandOnClick: Bool {
        didSet { defaults.set(musicExpandOnClick, forKey: Key.musicExpandOnClick) }
    }

    @Published var musicExpandedTimeout: TimeInterval {
        didSet { defaults.set(musicExpandedTimeout, forKey: Key.musicExpandedTimeout) }
    }

    @Published var hudDockPosition: HUDDockPosition {
        didSet { defaults.set(hudDockPosition.rawValue, forKey: Key.hudDockPosition) }
    }

    @Published private(set) var extensionShortcutOverrides: [String: String]
    /// Legacy extension-ID overrides remain readable so upgrades do not reset
    /// user choices. New settings write stable pack keys instead.
    @Published private(set) var extensionEnabledOverrides: [String: Bool]
    @Published private(set) var extensionPackEnabledOverrides: [String: Bool]
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
        contextShelfCaptureShortcut = defaults.string(forKey: Key.contextShelfCaptureShortcut) ?? "control+option+s"
        contextShelfCaptureHotkeyEnabled = defaults.object(forKey: Key.contextShelfCaptureHotkeyEnabled) as? Bool ?? false
        terminalHotkeyEnabled = defaults.object(forKey: Key.terminalHotkeyEnabled) as? Bool ?? false
        accessoryMouseBindings = defaults.dictionary(forKey: Key.accessoryMouseBindings) as? [String: String] ?? [:]
        accentTheme = AppAccentTheme(rawValue: defaults.string(forKey: Key.accentTheme) ?? "") ?? .violet
        contrastMode = AppContrastMode(rawValue: defaults.string(forKey: Key.contrastMode) ?? "") ?? .standard
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        interfaceDensity = AppInterfaceDensity(rawValue: defaults.string(forKey: Key.interfaceDensity) ?? "") ?? .balanced
        notesVisualTheme = NotesVisualTheme(rawValue: defaults.string(forKey: Key.notesVisualTheme) ?? "") ?? .prism
        notesFontStyle = NotesFontStyle(rawValue: defaults.string(forKey: Key.notesFontStyle) ?? "") ?? .system
        let storedNotesFontSize = defaults.double(forKey: Key.notesFontSize)
        notesFontSize = storedNotesFontSize == 0 ? 15.5 : storedNotesFontSize
        let storedNotesLineSpacing = defaults.double(forKey: Key.notesLineSpacing)
        notesLineSpacing = storedNotesLineSpacing == 0 ? 3.5 : storedNotesLineSpacing
        notesContentWidth = NotesContentWidth(rawValue: defaults.string(forKey: Key.notesContentWidth) ?? "") ?? .wide
        notesShowMetadata = defaults.object(forKey: Key.notesShowMetadata) as? Bool ?? true
        let storedQuickNoteOpacity = defaults.double(forKey: Key.quickNoteOpacity)
        quickNoteOpacity = storedQuickNoteOpacity == 0 ? 0.96 : storedQuickNoteOpacity
        quickNoteAutoHide = defaults.object(forKey: Key.quickNoteAutoHide) as? Bool ?? false
        quickNotePerSpaceMemory = defaults.object(forKey: Key.quickNotePerSpaceMemory) as? Bool ?? true
        quickNoteDisplayLocked = defaults.object(forKey: Key.quickNoteDisplayLocked) as? Bool ?? false
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? false
        let storedLimit = defaults.integer(forKey: Key.clipboardLimit)
        clipboardLimit = storedLimit == 0 ? 50 : storedLimit
        // Lima is a regular Mac app now. Existing installs that never chose a
        // visibility preference gain a Dock icon automatically; an explicit
        // stored preference is still respected.
        showInDock = defaults.object(forKey: Key.showInDock) as? Bool ?? true
        writingInstructions = defaults.string(forKey: Key.writingInstructions) ?? Self.defaultWritingInstructions
        writingPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.writingPerformance) ?? "") ?? .eco
        // The keyboard command is useful immediately after installation.
        // Existing explicit user choices remain respected.
        stealthGrammarEnabled = defaults.object(forKey: Key.stealthGrammarEnabled) as? Bool ?? true
        stealthGrammarShortcut = defaults.string(forKey: Key.stealthGrammarShortcut) ?? "control+option+g"
        let legacyExternalGrammar = defaults.object(forKey: Key.developerGrammarEnabled) as? Bool ?? false
        grammarEngineMode = GrammarEngineMode(
            rawValue: defaults.string(forKey: Key.grammarEngineMode) ?? ""
        ) ?? (legacyExternalGrammar ? .externalAPI : .local)
        grammarCorrectionMode = GrammarCorrectionMode(
            rawValue: defaults.string(forKey: Key.grammarCorrectionMode) ?? ""
        ) ?? .proofread
        grammarEnsembleStrategy = GrammarEnsembleStrategy(
            rawValue: defaults.string(forKey: Key.grammarEnsembleStrategy) ?? ""
        ) ?? .balanced
        grammarJudgeOnDisagreement = defaults.object(forKey: Key.grammarJudgeOnDisagreement) as? Bool ?? true
        grammarDebugStoreSourceText = defaults.object(forKey: Key.grammarDebugStoreSourceText) as? Bool ?? false
        grammarDebugRetentionDays = min(max(defaults.object(forKey: Key.grammarDebugRetentionDays) as? Int ?? 30, 1), 3650)
        grammarDebugMaximumRuns = min(max(defaults.object(forKey: Key.grammarDebugMaximumRuns) as? Int ?? 500, 10), 100_000)
        let storedDeveloperProvider = DeveloperGrammarProvider(rawValue: defaults.string(forKey: Key.developerGrammarProvider) ?? "") ?? .openAI
        developerGrammarProvider = storedDeveloperProvider
        developerGrammarModel = defaults.string(forKey: Key.developerGrammarModel) ?? storedDeveloperProvider.defaultModel
        developerGrammarBaseURL = defaults.string(forKey: Key.developerGrammarBaseURL) ?? storedDeveloperProvider.defaultBaseURL
        defaults.set(false, forKey: Key.grammarFallbackToLocal)
        inlineGrammarCheckingEnabled = defaults.object(forKey: Key.inlineGrammarCheckingEnabled) as? Bool ?? true
        dictationPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.dictationPerformance) ?? "") ?? .eco
        dictationEngine = DictationEngine(rawValue: defaults.string(forKey: Key.dictationEngine) ?? "") ?? .localWhisper
        dictationComputeMode = DictationComputeMode(rawValue: defaults.string(forKey: Key.dictationComputeMode) ?? "") ?? .automatic
        extensionPerformance = PerformanceScale(rawValue: defaults.string(forKey: Key.extensionPerformance) ?? "") ?? .eco
        dynamicPerformance = defaults.object(forKey: Key.dynamicPerformance) as? Bool ?? false
        launcherSurfaceTimeout = defaults.object(forKey: Key.launcherSurfaceTimeout) as? Double ?? 30
        terminalUsesLauncherTimeout = defaults.object(forKey: Key.terminalUsesLauncherTimeout) as? Bool ?? false
        musicHUDPresentation = MusicHUDPresentation(rawValue: defaults.string(forKey: Key.musicHUDPresentation) ?? "") ?? .compact
        musicShowArtwork = defaults.object(forKey: Key.musicShowArtwork) as? Bool ?? true
        musicShowPlaybackControls = defaults.object(forKey: Key.musicShowPlaybackControls) as? Bool ?? true
        musicShowProgress = defaults.object(forKey: Key.musicShowProgress) as? Bool ?? true
        musicShowWhenPaused = defaults.object(forKey: Key.musicShowWhenPaused) as? Bool ?? true
        musicExpandOnClick = defaults.object(forKey: Key.musicExpandOnClick) as? Bool ?? true
        musicExpandedTimeout = defaults.object(forKey: Key.musicExpandedTimeout) as? Double ?? 5
        hudDockPosition = HUDDockPosition(rawValue: defaults.string(forKey: Key.hudDockPosition) ?? "") ?? .bottomCenter
        extensionShortcutOverrides = defaults.dictionary(forKey: Key.extensionShortcutOverrides) as? [String: String] ?? [:]
        extensionEnabledOverrides = defaults.dictionary(forKey: Key.extensionEnabledOverrides) as? [String: Bool] ?? [:]
        extensionPackEnabledOverrides = defaults.dictionary(forKey: Key.extensionPackEnabledOverrides) as? [String: Bool] ?? [:]
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

    func restoreContextShelfCaptureShortcut(_ shortcut: String) {
        isRestoringActionShortcut = true
        contextShelfCaptureShortcut = shortcut
        isRestoringActionShortcut = false
    }

    func restoreTerminalShortcut(_ shortcut: String) { isRestoringActionShortcut = true; terminalShortcut = shortcut; isRestoringActionShortcut = false }

    func restoreStealthGrammarShortcut(_ shortcut: String) {
        isRestoringActionShortcut = true
        stealthGrammarShortcut = shortcut
        isRestoringActionShortcut = false
    }

    func accessoryMouseBinding(for button: Int) -> AccessoryMouseBinding {
        guard (3...8).contains(button) else { return .none }
        return AccessoryMouseBinding(storageValue: accessoryMouseBindings[String(button)])
    }

    func setAccessoryMouseBinding(_ binding: AccessoryMouseBinding, for button: Int) {
        guard (3...8).contains(button) else { return }
        if let storageValue = binding.storageValue {
            accessoryMouseBindings[String(button)] = storageValue
        } else {
            accessoryMouseBindings.removeValue(forKey: String(button))
        }
    }

    func accessoryMouseShortcut(for button: Int) -> String {
        guard case .shortcut(let shortcut) = accessoryMouseBinding(for: button) else { return "" }
        return shortcut
    }

    func setAccessoryMouseShortcut(_ shortcut: String, for button: Int) {
        guard (3...8).contains(button) else { return }
        setAccessoryMouseBinding(.shortcut(shortcut), for: button)
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

    func isPackEnabled(for loaded: LoadedExtensionCommand) -> Bool {
        extensionPackEnabledOverrides[loaded.settingsPackKey]
            ?? isExtensionEnabled(loaded.extensionID)
    }

    func setPackEnabled(_ enabled: Bool, for loaded: LoadedExtensionCommand) {
        extensionPackEnabledOverrides[loaded.settingsPackKey] = enabled
        defaults.set(extensionPackEnabledOverrides, forKey: Key.extensionPackEnabledOverrides)
        notifyExtensionConfigurationChanged()
    }

    /// Retained for settings migrations and user extensions that predate pack
    /// metadata. New UI writes the pack-level store through `setPackEnabled`.
    func setExtensionEnabled(_ enabled: Bool, extensionID: String) {
        extensionEnabledOverrides[extensionID] = enabled
        defaults.set(extensionEnabledOverrides, forKey: Key.extensionEnabledOverrides)
        notifyExtensionConfigurationChanged()
    }

    func isCommandEnabled(_ loaded: LoadedExtensionCommand) -> Bool {
        isPackEnabled(for: loaded) && isExtensionEnabled(loaded.extensionID)
    }

    func isHotkeyEnabled(_ loaded: LoadedExtensionCommand) -> Bool {
        isCommandEnabled(loaded)
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

    func importBackupValues(_ values: [String: LimaBackupValue]) throws {
        let secretTerms = ["secret", "password", "token", "apikey", "api_key", "credential"]
        for (key, value) in values {
            let normalized = key.lowercased()
            guard !secretTerms.contains(where: { normalized.contains($0) }) else { continue }
            applyImportedValue(value, forKey: key)
        }
        NotificationCenter.default.post(name: .rayPlacementShortcutChanged, object: nil)
        NotificationCenter.default.post(name: .rayPlacementActionShortcutsChanged, object: nil)
        NotificationCenter.default.post(name: .rayPlacementAppearanceChanged, object: nil)
        NotificationCenter.default.post(name: .rayPlacementClipboardSettingsChanged, object: nil)
    }

    private func applyImportedValue(_ value: LimaBackupValue, forKey key: String) {
        func string() -> String? { if case .string(let value) = value { return value }; return nil }
        func bool() -> Bool? { if case .bool(let value) = value { return value }; return nil }
        func int() -> Int? {
            switch value {
            case .integer(let value): return value
            case .double(let value): return Int(value)
            default: return nil
            }
        }
        func double() -> Double? {
            switch value {
            case .double(let value): return value
            case .integer(let value): return Double(value)
            default: return nil
            }
        }

        switch key {
        case Key.activationShortcut: if let value = string() { activationShortcut = value }
        case Key.activationHotkeyEnabled: if let value = bool() { activationHotkeyEnabled = value }
        case Key.notesShortcut: if let value = string() { notesShortcut = value }
        case Key.notesHotkeyEnabled: if let value = bool() { notesHotkeyEnabled = value }
        case Key.quickNoteShortcut: if let value = string() { quickNoteShortcut = value }
        case Key.quickNoteHotkeyEnabled: if let value = bool() { quickNoteHotkeyEnabled = value }
        case Key.dictationShortcut: if let value = string() { dictationShortcut = value }
        case Key.dictationHotkeyEnabled: if let value = bool() { dictationHotkeyEnabled = value }
        case Key.notesDockLeftShortcut: if let value = string() { notesDockLeftShortcut = value }
        case Key.notesDockLeftHotkeyEnabled: if let value = bool() { notesDockLeftHotkeyEnabled = value }
        case Key.notesDockRightShortcut: if let value = string() { notesDockRightShortcut = value }
        case Key.notesDockRightHotkeyEnabled: if let value = bool() { notesDockRightHotkeyEnabled = value }
        case Key.terminalShortcut: if let value = string() { terminalShortcut = value }
        case Key.terminalHotkeyEnabled: if let value = bool() { terminalHotkeyEnabled = value }
        case Key.contextShelfCaptureShortcut: if let value = string() { contextShelfCaptureShortcut = value }
        case Key.contextShelfCaptureHotkeyEnabled: if let value = bool() { contextShelfCaptureHotkeyEnabled = value }
        case Key.accentTheme:
            if let value = string(), let parsed = AppAccentTheme(rawValue: value) { accentTheme = parsed }
        case Key.contrastMode:
            if let value = string(), let parsed = AppContrastMode(rawValue: value) { contrastMode = parsed }
        case Key.appearance:
            if let value = string(), let parsed = AppAppearance(rawValue: value) { appearance = parsed }
        case Key.interfaceDensity:
            if let value = string(), let parsed = AppInterfaceDensity(rawValue: value) { interfaceDensity = parsed }
        case Key.notesVisualTheme:
            if let value = string(), let parsed = NotesVisualTheme(rawValue: value) { notesVisualTheme = parsed }
        case Key.notesFontStyle:
            if let value = string(), let parsed = NotesFontStyle(rawValue: value) { notesFontStyle = parsed }
        case Key.notesFontSize: if let value = double() { notesFontSize = value }
        case Key.notesLineSpacing: if let value = double() { notesLineSpacing = value }
        case Key.notesContentWidth:
            if let value = string(), let parsed = NotesContentWidth(rawValue: value) { notesContentWidth = parsed }
        case Key.notesShowMetadata: if let value = bool() { notesShowMetadata = value }
        case Key.quickNoteOpacity: if let value = double() { quickNoteOpacity = value }
        case Key.quickNoteAutoHide: if let value = bool() { quickNoteAutoHide = value }
        case Key.quickNotePerSpaceMemory: if let value = bool() { quickNotePerSpaceMemory = value }
        case Key.quickNoteDisplayLocked: if let value = bool() { quickNoteDisplayLocked = value }
        case Key.clipboardEnabled: if let value = bool() { clipboardEnabled = value }
        case Key.clipboardLimit: if let value = int() { clipboardLimit = value }
        case Key.showInDock: if let value = bool() { showInDock = value }
        case Key.writingInstructions: if let value = string() { writingInstructions = value }
        case Key.writingPerformance:
            if let value = string(), let parsed = PerformanceScale(rawValue: value) { writingPerformance = parsed }
        case Key.stealthGrammarEnabled: if let value = bool() { stealthGrammarEnabled = value }
        case Key.stealthGrammarShortcut: if let value = string() { stealthGrammarShortcut = value }
        case Key.developerGrammarEnabled: if let value = bool() { grammarEngineMode = value ? .externalAPI : .local }
        case Key.grammarCorrectionMode:
            if let value = string(), let parsed = GrammarCorrectionMode(rawValue: value) { grammarCorrectionMode = parsed }
        case Key.grammarEnsembleStrategy:
            if let value = string(), let parsed = GrammarEnsembleStrategy(rawValue: value) { grammarEnsembleStrategy = parsed }
        case Key.grammarJudgeOnDisagreement: if let value = bool() { grammarJudgeOnDisagreement = value }
        case Key.grammarDebugStoreSourceText: if let value = bool() { grammarDebugStoreSourceText = value }
        case Key.grammarDebugRetentionDays: if let value = int() { grammarDebugRetentionDays = value }
        case Key.grammarDebugMaximumRuns: if let value = int() { grammarDebugMaximumRuns = value }
        case Key.developerGrammarProvider:
            if let value = string(), let parsed = DeveloperGrammarProvider(rawValue: value) { developerGrammarProvider = parsed }
        case Key.developerGrammarModel: if let value = string() { developerGrammarModel = value }
        case Key.developerGrammarBaseURL: if let value = string() { developerGrammarBaseURL = value }
        case Key.grammarFallbackToLocal: defaults.set(false, forKey: Key.grammarFallbackToLocal)
        case Key.inlineGrammarCheckingEnabled: if let value = bool() { inlineGrammarCheckingEnabled = value }
        case Key.dictationPerformance:
            if let value = string(), let parsed = PerformanceScale(rawValue: value) { dictationPerformance = parsed }
        case Key.dictationEngine:
            if let value = string(), let parsed = DictationEngine(rawValue: value) { dictationEngine = parsed }
        case Key.dictationComputeMode:
            if let value = string(), let parsed = DictationComputeMode(rawValue: value) { dictationComputeMode = parsed }
        case Key.extensionPerformance:
            if let value = string(), let parsed = PerformanceScale(rawValue: value) { extensionPerformance = parsed }
        case Key.dynamicPerformance: if let value = bool() { dynamicPerformance = value }
        default: break
        }
    }

    func exportBackup(to destination: URL? = nil) throws -> URL {
        let target = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("Lima-Settings-\(Int(Date().timeIntervalSince1970)).json")
        let snapshot = defaults.dictionaryRepresentation().filter { key, value in
            !key.lowercased().contains("key") && !key.lowercased().contains("secret") && !(value is Data)
        }
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

}
