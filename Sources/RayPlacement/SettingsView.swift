import AppKit
import ApplicationServices
import RayPlacementCore
import RayPlacementWriting
import SwiftUI

private extension LoadedExtensionCommand {
    var settingsIdentifier: String { "\(extensionID).\(command.id)" }
}

private struct SettingsExtensionGroup: Identifiable {
    let id: String
    let name: String
    let category: String
    let provenance: String
    let commands: [LoadedExtensionCommand]
}

private struct PendingShortcutAssignment: Identifiable {
    let id = UUID()
    let targetID: String
    let targetTitle: String
    let shortcut: String
    let conflictID: String
    let conflictTitle: String
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case workspace
    case commands
    case writing
    case ai
    case browser
    case appearance
    case advanced

    static let sidebarSections = Self.allCases

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .workspace: return "Workspace"
        case .commands: return "Command Center"
        case .writing: return "Writing & Dictation"
        case .ai: return "AI Chat"
        case .browser: return "Browser Bridge"
        case .appearance: return "Appearance"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .workspace: return "square.stack.3d.up"
        case .commands: return "square.grid.2x2"
        case .writing: return "text.badge.checkmark"
        case .ai: return "sparkles"
        case .browser: return "globe"
        case .appearance: return "paintbrush.fill"
        case .advanced: return "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "App behavior and local preferences"
        case .workspace: "Sections, modules, rail, and layouts"
        case .commands: "Commands, extensions, and shortcuts"
        case .writing: "Notes, grammar, and speech to text"
        case .ai: "Existing providers and chat behavior"
        case .browser: "Browser access and site grants"
        case .appearance: "Theme, colors, and readable layouts"
        case .advanced: "Performance, privacy, and diagnostics"
        }
    }

    var tint: AppAccentTheme {
        switch self {
        case .general, .workspace, .commands: .blue
        case .writing: .green
        case .ai, .appearance: .violet
        case .browser: .cyan
        case .advanced: .graphite
        }
    }

    var searchTerms: [String] {
        switch self {
        case .general:
            return ["startup", "launcher", "updates", "login", "behavior", "default"]
        case .workspace:
            return ["workspace", "layout", "rail", "section", "module", "startup", "profile", "visibility"]
        case .commands:
            return ["commands", "shortcuts", "hotkeys", "built-in", "extension", "tools", "skills", "agents", "conflict", "key", "store", "updates"]
        case .writing:
            return ["writing", "grammar", "spelling", "proofread", "AI", "Harper", "dictation", "microphone", "notes"]
        case .ai:
            return ["ai", "chat", "provider", "model", "anthropic", "claude", "openai", "gemini", "compatible", "endpoint", "api key", "reasoning"]
        case .browser:
            return ["zen", "firefox", "browser", "bridge", "site", "permissions", "native", "helper", "salesforce", "tabs"]
        case .appearance:
            return ["appearance", "theme", "text size", "density", "animation", "motion", "accent"]
        case .advanced:
            return ["advanced", "experimental", "browser interaction", "performance", "privacy", "permissions", "usage", "logs", "developer", "secrets", "diagnostics", "clipboard"]
        }
    }

    func matches(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let searchableText = ([title] + searchTerms).joined(separator: " ").lowercased()
        let terms = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return terms.allSatisfy { searchableText.contains($0) }
    }
}

@MainActor
private enum SettingsColors {
    static var indigo: Color { SettingsStore.shared.accentTheme.primary }
    static var violet: Color { SettingsStore.shared.accentTheme.secondary }
    static var cyan: Color { SettingsStore.shared.accentTheme.tertiary }
    static var readableIndigo: Color { SettingsStore.shared.accentTheme.readablePrimary }
    static var readableViolet: Color { SettingsStore.shared.accentTheme.readableSecondary }
    static var readableCyan: Color { SettingsStore.shared.accentTheme.readableTertiary }
    static var heroGradient: LinearGradient { SettingsStore.shared.accentTheme.gradient }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var aiChatModel: AIChatViewModel
    @ObservedObject var updateService: UpdateService
    @ObservedObject private var usageMonitor = UsageMonitor.shared
    @ObservedObject private var taskRegistry = TaskRegistry.shared
    @ObservedObject private var performanceMonitor = PerformanceMonitor.shared
    @ObservedObject private var commandManager = CommandManager.shared
    @ObservedObject private var workspaceProfiles = WorkspaceProfileStore.shared
    @ObservedObject private var permissionCenter = PermissionCenter.shared
    @ObservedObject private var backups = DataBackupCoordinator.shared
    @ObservedObject private var secrets = LimaSecretStore.shared
    @ObservedObject private var actionPolicy = AIComputerActionPolicy.shared
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var secretKind: LimaSecretKind = .localSecret
    @State private var editingSecretID: UUID?
    @State private var confirmClipboardClear = false
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var selectedSection: SettingsSection = .general
    @State private var settingsSearchQuery = ""
    @State private var advancedSubsection = 0
    @State private var writingSubsection = 0
    @State private var confirmUsageClear = false
    @State private var confirmCloudDictation = false
    @State private var commandProfileName = ""
    @State private var aliasDrafts: [String: String] = [:]
    @State private var shortcutLookupDraft = ""
    @State private var pendingShortcutAssignment: PendingShortcutAssignment?
    @State private var workspaceProfileName = ""
    @State private var developerTraceMessage: String?
    @State private var grammarAPIKey = ""
    @State private var grammarConnectionMessage: String?
    @State private var isTestingGrammarConnection = false
    @State private var grammarCompatibilityMessage: String?
    @State private var isTestingGrammarCompatibility = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reloadExtensions: () -> Void
    let openGrammarDebugger: () -> Void
    @ObservedObject var extensionStoreModel: ExtensionStoreModel

    var body: some View {
        LimaChrome {
            HStack(spacing: LimaDesign.panelGap) {
                settingsSidebar
                VStack(spacing: 0) {
                    HStack {
                        LimaWorkspaceHeading(title: selectedSection.title, subtitle: selectedSection.subtitle,
                                             symbol: selectedSection.symbol, tint: selectedSection.tint)
                        LimaWindowDragRegion()
                            .frame(minWidth: 44, maxWidth: .infinity)
                            .frame(height: 32)
                    }
                    .padding(.horizontal, LimaDesign.toolbarPadding)
                    .padding(.vertical, 20)
                    .limaGlassContainer(region: .toolbar, cornerRadius: LimaRadius.window)
                    GlassHairline()
                    selectedContent
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.992)))
                }
                .limaContentSurface(cornerRadius: LimaRadius.window, fill: LimaTheme.surfaceRaised)
            }
            .padding(LimaDesign.windowPadding)
        }
        .frame(minWidth: 900, idealWidth: 1060, minHeight: 620, idealHeight: 760)
        .tint(settings.accentTheme.readablePrimary)
        .limaAnimation(LimaDesign.spring(0.30), value: selectedSection)
        .onReceive(settings.$requestedSettingsSection) { requested in
            if let requested { selectedSection = requested }
        }
        .onChange(of: settingsSearchQuery) { query in
            if let first = filteredSections.first {
                selectedSection = first
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedSection = .general
            }
        }
        .alert("Clear usage log?", isPresented: $confirmUsageClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Log", role: .destructive) { usageMonitor.clear() }
        } message: {
            Text("This permanently removes Lima's local task history. It never contains your selected text or document contents.")
        }
        .alert("Send dictation audio to OpenAI?", isPresented: $confirmCloudDictation) {
            Button("Keep On-device", role: .cancel) {}
            Button("Use OpenAI Cloud") { settings.dictationEngine = .openAICloud }
        } message: {
            Text("When you stop recording, Lima sends each recorded audio segment to OpenAI for transcription using your OpenAI API key. This is off-device and may incur provider charges. Recordings stay on your Mac if transcription fails; choose a local engine at any time.")
        }
        .alert(item: $pendingShortcutAssignment) { request in
            Alert(
                title: Text("Shortcut conflict"),
                message: Text("\(ShortcutSpec(string: request.shortcut)?.displayString ?? request.shortcut) is already assigned to \(request.conflictTitle). Reassign it to \(request.targetTitle)?"),
                primaryButton: .default(Text("Reassign")) {
                    applyShortcut("", to: request.conflictID)
                    applyShortcut(request.shortcut, to: request.targetID)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var dictationEngineBinding: Binding<DictationEngine> {
        Binding(
            get: { settings.dictationEngine },
            set: { engine in
                if engine == .openAICloud && settings.dictationEngine != .openAICloud {
                    confirmCloudDictation = true
                } else {
                    settings.dictationEngine = engine
                }
            }
        )
    }

    private func shortcutBinding(for assignmentID: String) -> Binding<String> {
        Binding(
            get: { shortcutValue(for: assignmentID) },
            set: { requestShortcutAssignment($0, to: assignmentID) }
        )
    }

    private func shortcutValue(for assignmentID: String) -> String {
        switch assignmentID {
        case "builtin.activation": return settings.activationShortcut
        case "builtin.notes": return settings.notesShortcut
        case "builtin.quick-note": return settings.quickNoteShortcut
        case "builtin.dictation": return settings.dictationShortcut
        case "builtin.notes-dock-left": return settings.notesDockLeftShortcut
        case "builtin.notes-dock-right": return settings.notesDockRightShortcut
        case "builtin.terminal": return settings.terminalShortcut
        case "builtin.context-shelf.capture-selection": return settings.contextShelfCaptureShortcut
        case "builtin.stealth-grammar": return settings.stealthGrammarShortcut
        default:
            return extensionCommand(for: assignmentID).flatMap { settings.effectiveShortcut(for: $0) } ?? ""
        }
    }

    private func requestShortcutAssignment(_ shortcut: String, to assignmentID: String) {
        guard !shortcut.isEmpty else {
            applyShortcut(shortcut, to: assignmentID)
            return
        }
        guard ShortcutSpec(string: shortcut) != nil else { return }

        commandManager.validateShortcuts(viewModel.extensionCommands)
        guard let conflict = commandManager.shortcutRegistry.conflict(for: shortcut, excluding: assignmentID) else {
            applyShortcut(shortcut, to: assignmentID)
            return
        }
        pendingShortcutAssignment = PendingShortcutAssignment(
            targetID: assignmentID,
            targetTitle: shortcutTitle(for: assignmentID),
            shortcut: shortcut,
            conflictID: conflict.id,
            conflictTitle: conflict.title
        )
    }

    private func applyShortcut(_ shortcut: String, to assignmentID: String) {
        switch assignmentID {
        case "builtin.activation": settings.activationShortcut = shortcut
        case "builtin.notes": settings.notesShortcut = shortcut
        case "builtin.quick-note": settings.quickNoteShortcut = shortcut
        case "builtin.dictation": settings.dictationShortcut = shortcut
        case "builtin.notes-dock-left": settings.notesDockLeftShortcut = shortcut
        case "builtin.notes-dock-right": settings.notesDockRightShortcut = shortcut
        case "builtin.terminal": settings.terminalShortcut = shortcut
        case "builtin.context-shelf.capture-selection": settings.contextShelfCaptureShortcut = shortcut
        case "builtin.stealth-grammar": settings.stealthGrammarShortcut = shortcut
        default:
            if let command = extensionCommand(for: assignmentID) {
                settings.setShortcut(shortcut.isEmpty ? nil : shortcut, for: command)
            }
        }
        commandManager.validateShortcuts(viewModel.extensionCommands)
    }

    private func shortcutTitle(for assignmentID: String) -> String {
        let titles = [
            "builtin.activation": "Open Search",
            "builtin.notes": "Notes",
            "builtin.quick-note": "Quick Note",
            "builtin.dictation": "Dictation",
            "builtin.notes-dock-left": "Dock Notes Left",
            "builtin.notes-dock-right": "Dock Notes Right",
            "builtin.terminal": "Terminal",
            "builtin.context-shelf.capture-selection": "Add Selection to Shelf",
            "builtin.stealth-grammar": "Fix Writing"
        ]
        return titles[assignmentID] ?? extensionCommand(for: assignmentID).map {
            "\($0.extensionName): \($0.command.title)"
        } ?? "Lima command"
    }

    private func extensionCommand(for assignmentID: String) -> LoadedExtensionCommand? {
        viewModel.extensionCommands.first {
            "extension.\($0.extensionID).\($0.command.id)" == assignmentID
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                LimaWayfinderMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings").limaFont(.system(size: 23, weight: .bold))
                    Text("Make Lima fit your workflow.").limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 18)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LimaTheme.textSecondary)
                    .font(.system(size: 11, weight: .semibold))
                TextField("Search settings", text: $settingsSearchQuery)
                    .textFieldStyle(.plain)
                    .limaFont(.system(size: 12.5))
                if !settingsSearchQuery.isEmpty {
                    Button { settingsSearchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LimaTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaTheme.borderSubtle, lineWidth: LimaDesign.borderWidth))
            .padding(.horizontal, 9)
            .padding(.bottom, 10)

            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
               if settingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sidebarGroup("SETTINGS", sections: SettingsSection.sidebarSections)
            } else if filteredSections.isEmpty {
                Text("No matching settings")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            } else {
                Text("RESULTS")
                    .limaFont(.system(size: 9, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(LimaTheme.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                ForEach(filteredSections) { settingsRow($0) }
               }
              }
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 10)
            settingsStatusSummary
                .padding(.horizontal, 11)
                .padding(.bottom, 11)
        }
        .frame(width: 268)
        .limaGlassContainer(region: .sidebar, cornerRadius: LimaRadius.window)
    }

    private var filteredSections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.matches(settingsSearchQuery) }
    }

    @ViewBuilder
    private func sidebarGroup(_ title: String, sections: [SettingsSection]) -> some View {
        Text(title)
            .limaFont(.system(size: 9, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(LimaTheme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 3)
        ForEach(sections) { settingsRow($0) }
    }

    private func settingsRow(_ section: SettingsSection) -> some View {
        Button { selectedSection = section } label: {
            HStack(spacing: 9) {
                LimaFeatureIcon(symbol: section.symbol, tint: section.tint, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .limaFont(.system(size: 14, weight: selectedSection == section ? .semibold : .medium))
                    Text(section.subtitle).limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .foregroundStyle(selectedSection == section ? Color.primary : LimaTheme.textPrimary.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(minHeight: 62)
            .limaSelection(selectedSection == section, radius: 12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .accessibilityValue(selectedSection == section ? "Selected" : "")
    }

    private var settingsStatusSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("STATUS")
                .limaFont(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(LimaTheme.textTertiary)
            SettingsCompactStatus(title: "Accessibility", value: compactPermission(.accessibility))
            SettingsCompactStatus(title: "Microphone", value: compactPermission(.microphone))
            SettingsCompactStatus(title: "Dictation engine", value: settings.dictationEngine == .localWhisper ? "Local Whisper" : "Apple Speech")
            SettingsCompactStatus(
                title: "Correction Engine",
                value: settings.grammarEngineMode == .externalAPI
                    ? (settings.enhancedGrammarAPIKeyStored ? "External API · Connected" : "External API · Needs key")
                    : "Local"
            )
            SettingsCompactStatus(title: "Extension commands", value: "\(viewModel.extensionCommands.count) loaded")
        }
        .padding(9)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
    }

    private func compactPermission(_ id: PermissionCenter.PermissionID) -> String {
        switch permissionCenter.statuses[id] {
        case .granted: return "Allowed"
        case .denied: return "Needs attention"
        case .unavailable: return "Unavailable"
        case .none: return "Checking…"
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .general: generalTab
        case .workspace: workspaceSettingsTab
        case .commands: commandCenterTab
        case .writing: writingSettingsTab
        case .ai: AIProviderSettingsView(model: aiChatModel)
        case .browser: BrowserBridgeSettingsView()
        case .appearance: appearanceSettingsTab
        case .advanced: advancedSettingsTab
        }
    }

    private var writingSettingsTab: some View {
        VStack(spacing: 0) {
            Picker("Writing area", selection: $writingSubsection) {
                Text("Fix Writing").tag(0)
                Text("Dictation").tag(1)
                Text("Writing Advanced").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(12)
            Group {
                switch writingSubsection {
                case 1: dictationTab
                case 2: GrammarSettingsView(settings: settings, openDebugger: openGrammarDebugger)
                default: grammarSettingsTab
                }
            }
        }
    }

    private var workspaceSettingsTab: some View {
        Form {
            Section("Customize Workspace") {
                WorkspaceConfigurationEditor(settings: settings)
            }
            Section("Home") {
                HomeWorkspaceConfigurationEditor(settings: settings)
            }
            Section("Workspace profiles") {
                Picker("Active profile", selection: Binding(
                    get: { workspaceProfiles.activeProfileID ?? workspaceProfiles.profiles.first?.id },
                    set: { id in if let id, let profile = workspaceProfiles.profiles.first(where: { $0.id == id }) { workspaceProfiles.activate(profile) } }
                )) {
                    ForEach(workspaceProfiles.profiles) { profile in
                        Text(profile.favorite ? "★ \(profile.name)" : profile.name).tag(Optional(profile.id))
                    }
                }
                HStack {
                    TextField("New profile name", text: $workspaceProfileName)
                    Button("Create") {
                        _ = workspaceProfiles.create(name: workspaceProfileName.isEmpty ? "New Workspace" : workspaceProfileName)
                        workspaceProfileName = ""
                    }
                    Button("Save Current") { workspaceProfiles.captureCurrentState() }
                    Button("Restore") { workspaceProfiles.restoreActiveState() }
                }
                if let error = workspaceProfiles.lastError { Text(error).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var appearanceSettingsTab: some View {
        Form {
            Section("Theme") {
                Picker("Color scheme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                AccentThemePicker(selection: $settings.accentTheme)
                Picker("Contrast", selection: $settings.contrastMode) {
                    ForEach(AppContrastMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(settings.contrastMode.detail).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                Picker("Glass", selection: $settings.glassStyle) {
                    ForEach(AppGlassStyle.allCases) { Text($0.title).tag($0) }
                }
                Text("Glass affects navigation and controls; notes, messages, and results stay quiet. Reduce Transparency uses opaque surfaces.")
                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Layout") {
                InterfaceTextSizeControl()
                Picker("Interface density", selection: $settings.interfaceDensity) {
                    ForEach(AppInterfaceDensity.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.interfaceDensity.detail).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Motion") {
                Text("Lima follows the macOS Reduce Motion accessibility preference for transitions and animated surfaces.")
                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).controlSize(.small)
    }

    private var advancedSettingsTab: some View {
        VStack(spacing: 0) {
            Picker("Advanced area", selection: $advancedSubsection) {
                Text("Performance").tag(0)
                Text("Privacy & Permissions").tag(1)
                Text("Usage & Logs").tag(2)
                Text("Developer").tag(3)
                Text("Experimental").tag(4)
            }
            .pickerStyle(.segmented)
            .padding(12)
            Group {
                switch advancedSubsection {
                case 1: privacyTab
                case 2: usageTab
                case 3: secretsTab
                case 4: experimentalTab
                default: advancedTab
                }
            }
        }
    }


    private var experimentalTab: some View {
        Form {
            Section("Experimental Features") {
                Toggle("Browser AI interaction", isOn: Binding(
                    get: { actionPolicy.browserInteractionExperimentalEnabled },
                    set: { actionPolicy.setBrowserInteractionExperimentalEnabled($0) }
                ))
                Text("Off by default. Unlocks browser click, type, and submit actions in AI Settings. An enabled interaction policy, exact-site access, and a compatible signed Browser Bridge companion are still required. Click and type may use an explicitly selected Activity journal mode; form submission always asks in Lima. Browser reading and navigation do not require this switch.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var advancedTab: some View {
        Form {
            Section("Automatic allocation") {
                Toggle(isOn: $settings.dynamicPerformance) {
                    Label("Beta Dynamic Performance", systemImage: "gauge.with.dots.needle.67percent")
                }
                Label(settings.dynamicPerformanceDescription, systemImage: settings.dynamicPerformance ? "waveform.path.ecg" : "slider.horizontal.3")
                    .limaFont(.caption.weight(.medium))
                    .foregroundStyle(settings.dynamicPerformance ? settings.accentTheme.readablePrimary : .secondary)
            }

            Section("Local writing checks") {
                performanceSlider(
                    "Writing",
                    selection: $settings.writingPerformance,
                    active: settings.runtimeWritingPerformance
                )
                LabeledContent(
                    "Rule engine budget",
                    value: "\(settings.runtimeWritingPerformance.threadLimit) worker thread\(settings.runtimeWritingPerformance.threadLimit == 1 ? "" : "s")"
                )
            }

            Section("Dictation") {
                Picker("Transcription engine", selection: dictationEngineBinding) {
                    ForEach(DictationEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Text(settings.dictationEngine.detail)
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                if settings.dictationEngine == .openAICloud {
                    Text(aiChatModel.credentials.hasAPIKey(for: .openAI)
                         ? "OpenAI API key is available in Keychain."
                         : "Add an OpenAI API key in Settings → AI before recording.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                if settings.dictationEngine == .localWhisper {
                    Picker("Whisper compute", selection: $settings.dictationComputeMode) {
                        ForEach(DictationComputeMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }
                if settings.dictationEngine == .localWhisper {
                    Label("Live on-device preview when available · Whisper finalizes short segments", systemImage: "waveform.badge.mic")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                performanceSlider(
                    "Dictation",
                    selection: $settings.dictationPerformance,
                    active: settings.runtimeDictationPerformance
                )
                LabeledContent(
                    "Work limit",
                    value: "Record \(Int(settings.runtimeDictationPerformance.dictationMaximumDuration / 60)) min; no transcription timeout"
                )
            }

            Section("Executable extensions") {
                performanceSlider(
                    "Extensions",
                    selection: $settings.extensionPerformance,
                    active: settings.runtimeExtensionPerformance
                )
                LabeledContent(
                    "Process budget",
                    value: "\(settings.runtimeExtensionPerformance.threadLimit) cooperative thread\(settings.runtimeExtensionPerformance.threadLimit == 1 ? "" : "s"), \(settings.runtimeExtensionPerformance.timeoutDescription(settings.runtimeExtensionPerformance.extensionTimeout))"
                )
            }

            Section {
                DisclosureGroup("How limits work") {
                    Text("Dynamic mode lowers each slider when Low Power Mode or heat requires it. Dictation is the only feature that loads a speech model. Extension limits are cooperative, so install only code you trust.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                        .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var advancedDetails: some View {
        VStack(spacing: 0) {
            Picker("Advanced area", selection: $advancedSubsection) {
                Text("Performance").tag(0)
                Text("Usage").tag(1)
                Text("Secrets").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(12)
            Group {
                switch advancedSubsection {
                case 1: usageTab
                case 2: secretsTab
                default: advancedTab
                }
            }
        }
    }

    private func performanceSlider(
        _ title: String,
        selection: Binding<PerformanceScale>,
        active: PerformanceScale
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(settings.dynamicPerformance && active != selection.wrappedValue
                    ? "\(active.title) active · \(selection.wrappedValue.title) max"
                    : selection.wrappedValue.title)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { Double(selection.wrappedValue.level) },
                    set: { selection.wrappedValue = PerformanceScale.level(Int($0.rounded())) }
                ),
                in: 1...Double(PerformanceScale.allCases.count),
                step: 1
            )
            HStack {
                Text("Eco")
                Spacer()
                Text("Unbounded")
            }
            .limaFont(.caption2)
            .foregroundStyle(LimaTheme.textTertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) performance")
    }

    private var grammarEngineSection: some View {
        Section("Grammar Engine") {
            Picker("Writing mode", selection: $settings.grammarCorrectionMode) {
                ForEach(GrammarCorrectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(settings.grammarCorrectionMode.detail)
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)

            Picker("Correction engine", selection: $settings.grammarEngineMode) {
                Text("Local").tag(GrammarEngineMode.local)
                Text("External API").tag(GrammarEngineMode.externalAPI)
            }
            .pickerStyle(.segmented)
            if settings.grammarEngineMode == .externalAPI {
                Text("External API sends the checked text to the selected provider after protected spans are masked. It never falls back to Local on failure.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Picker("Ensemble", selection: $settings.grammarEnsembleStrategy) {
                    ForEach(GrammarEnsembleStrategy.allCases) { strategy in
                        Text("\(strategy.title) · \(strategy.detail)").tag(strategy)
                    }
                }
                Text("Candidates use fixed Lima diversity seeds and different proofreader profiles. Balanced is the default.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Picker("Provider", selection: Binding(
                    get: { settings.developerGrammarProvider },
                    set: { settings.selectDeveloperGrammarProvider($0) }
                )) {
                    ForEach(DeveloperGrammarProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Picker("Model", selection: $settings.developerGrammarModel) {
                    ForEach(settings.developerGrammarProvider.modelOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                    if !settings.developerGrammarProvider.modelOptions.contains(where: { $0.id == settings.developerGrammarModel }) {
                        Text("Custom: \(settings.developerGrammarModel)").tag(settings.developerGrammarModel)
                    }
                }
                TextField("Manual model ID", text: $settings.developerGrammarModel)
                    .textFieldStyle(.roundedBorder)
                SecureField("New API key", text: $grammarAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save API Key") {
                        do {
                            try settings.saveDeveloperGrammarAPIKey(grammarAPIKey)
                            grammarAPIKey = ""
                            grammarConnectionMessage = "Stored securely in Keychain."
                        } catch {
                            grammarConnectionMessage = error.localizedDescription
                        }
                    }
                    .disabled(grammarAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.enhancedGrammarAPIKeyStored {
                        Label("Stored securely in Keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .limaFont(.caption)
                    }
                }
                DisclosureGroup("Advanced provider settings") {
                    TextField("Provider Base URL", text: $settings.developerGrammarBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Usually no change is needed. Use this for a custom or OpenAI-compatible provider.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                if let grammarConnectionMessage {
                    Text(grammarConnectionMessage)
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                HStack(spacing: 10) {
                    Button {
                        testGrammarConnection()
                    } label: {
                        if isTestingGrammarConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test Connection", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(isTestingGrammarConnection || isTestingGrammarCompatibility || !settings.enhancedGrammarAPIKeyStored)

                    Button {
                        testExternalGrammar()
                    } label: {
                        if isTestingGrammarCompatibility {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test External Grammar", systemImage: "text.badge.checkmark")
                        }
                    }
                    .disabled(isTestingGrammarConnection || isTestingGrammarCompatibility || !settings.enhancedGrammarAPIKeyStored)
                }
                if let grammarCompatibilityMessage {
                    Text(grammarCompatibilityMessage)
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
            } else {
                Label("Everything stays on this Mac", systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("Python spelling and Harper grammar run locally. No API key is required.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
        }
    }

    private func testGrammarConnection() {
        guard let configuration = settings.developerGrammarConfigurationForTesting else {
            grammarConnectionMessage = "Save an API key and model first."
            return
        }
        isTestingGrammarConnection = true
        grammarConnectionMessage = nil
        let started = Date()
        StealthGrammarRemoteClient().testConnection(configuration: configuration) { result in
            let latency = Int(Date().timeIntervalSince(started) * 1_000)
            isTestingGrammarConnection = false
            switch result {
            case .success:
                grammarConnectionMessage = "Connected · \(configuration.provider.title) · \(configuration.model) · \(latency) ms"
            case .failure(let error):
                grammarConnectionMessage = "Failed · \(error.localizedDescription)"
            }
        }
    }

    private func testExternalGrammar() {
        guard let configuration = settings.developerGrammarConfigurationForTesting else {
            grammarCompatibilityMessage = "Save an API key and model first."
            return
        }
        isTestingGrammarCompatibility = true
        grammarCompatibilityMessage = nil
        let started = Date()
        let source = ExternalGrammarCompatibility.corpus
        let protected = StealthGrammarService.protect(source, ignoreList: "Lima")
        StealthGrammarRemoteClient().correctDocument(protected.contextText, configuration: configuration) { result in
            let latency = Int(Date().timeIntervalSince(started) * 1_000)
            isTestingGrammarCompatibility = false
            switch result {
            case .success(let changes):
                let report = protected.applyingDocumentChanges(changes)
                if ExternalGrammarCompatibility.validate(source: source, protected: protected, report: report) {
                    grammarCompatibilityMessage = "Compatible · applied \(report.appliedCount) · rejected \(report.rejectedCount) · \(latency) ms"
                } else {
                    grammarCompatibilityMessage = "Failed · the provider did not return safe atomic document changes"
                }
            case .failure(let error):
                grammarCompatibilityMessage = "Failed · \(error.localizedDescription)"
            }
        }
    }

    private var grammarSettingsTab: some View {
        SimpleWritingSettingsView(settings: settings, apiKey: $grammarAPIKey, shortcut: shortcutBinding(for: "builtin.stealth-grammar"))
    }

    private var dictationTab: some View {
        Form {
            Section("Dictation engine") {
                Picker("Transcription engine", selection: dictationEngineBinding) {
                    ForEach(DictationEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Text(settings.dictationEngine.detail)
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                if settings.dictationEngine == .openAICloud {
                    Text(aiChatModel.credentials.hasAPIKey(for: .openAI)
                         ? "OpenAI API key is available in Keychain."
                         : "Add an OpenAI API key in Settings → AI before recording.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                if settings.dictationEngine == .localWhisper {
                    Picker("Whisper compute", selection: $settings.dictationComputeMode) {
                        ForEach(DictationComputeMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }
            }
            Section("Recording") {
                Toggle("Enable dictation hotkey", isOn: $settings.dictationHotkeyEnabled)
                PrimaryShortcutRow(
                    title: "Dictation",
                    symbol: "mic.fill",
                    enabled: $settings.dictationHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.dictation")
                )
                Text(settings.dictationEngine == .openAICloud
                    ? "Recording stays on this Mac until Stop, then WAV segments are uploaded to OpenAI. A saved OpenAI API key is required. Committed text goes to the selected target; sending an AI prompt shares it with that conversation’s provider."
                    : "Speech recognition runs on this Mac. Start from the launcher, shortcut, or a Notes/AI microphone. Committed text goes to the selected target; sending an AI prompt shares it with that conversation’s provider.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
            Section("Performance") {
                performanceSlider("Dictation", selection: $settings.dictationPerformance, active: settings.runtimeDictationPerformance)
                LabeledContent("Recording limit", value: "\(Int(settings.runtimeDictationPerformance.dictationMaximumDuration / 60)) minutes")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var usageTab: some View {
        let summary = usageMonitor.summary
        let latencySamples = Array(LauncherPerformanceDiagnostics.shared.samples.suffix(8))
        let provider = aiChatModel.provider
        let credentialConfigured = aiChatModel.hasProviderAPIKey
        let runtime = DiagnosticsService.shared.runtimeSnapshot(
            provider: provider,
            providerCredentialConfigured: credentialConfigured,
            extensionIssueCount: viewModel.extensionIssues.count,
            dictationEngine: settings.dictationEngine
        )
        return Form {
            Section("Runtime diagnostics") {
                LabeledContent("App uptime", value: durationLabel(runtime.appUptime))
                LabeledContent(
                    "Resident memory",
                    value: runtime.residentMemoryBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
                    } ?? "Unavailable"
                )
                LabeledContent("Active tasks", value: runtime.activeTaskCount.formatted())
                LabeledContent("Recent failures", value: runtime.recentFailures.count.formatted())
                LabeledContent("AI provider", value: "\(runtime.provider.title) · \(runtime.providerStatus)")
                LabeledContent(
                    "Extensions",
                    value: runtime.extensionIssueCount == 0
                        ? "No issues"
                        : "\(runtime.extensionIssueCount) issue\(runtime.extensionIssueCount == 1 ? "" : "s")"
                )
                LabeledContent(
                    "Dictation",
                    value: "\(runtime.dictationEngine.title) · \(runtime.dictationIsActive ? "Active" : "Idle")"
                )
                if !runtime.recentFailures.isEmpty {
                    ForEach(runtime.recentFailures) { task in
                        Label(task.title, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Live activity") {
                if usageMonitor.activeTasks.isEmpty {
                    Label("No local process is running", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(usageMonitor.activeTasks) { task in
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.operation).limaFont(.callout.weight(.semibold))
                                Text("\(task.model ?? task.category.rawValue) · \(task.performance.title) · \(task.threads) threads")
                                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                            }
                            Spacer()
                            Text(task.startedAt, style: .timer).limaFont(.caption.monospacedDigit())
                        }
                    }
                }
            }

            Section("Activity Shelf") {
                if taskRegistry.activeTasks.isEmpty {
                    Text("No shared tasks are active. AI and extension work remains available here when you leave its surface.")
                        .foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(taskRegistry.activeTasks) { task in
                        HStack(spacing: 10) {
                            Image(systemName: task.kind.symbol)
                                .foregroundStyle(settings.accentTheme.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).limaFont(.callout.weight(.semibold))
                                Text(task.detail ?? task.state.rawValue.capitalized)
                                    .limaFont(.caption)
                                    .foregroundStyle(LimaTheme.textSecondary)
                            }
                            Spacer()
                            Text(task.startedAt, style: .timer)
                                .limaFont(.caption.monospacedDigit())
                            if task.isCancellable {
                                Button("Stop", role: .destructive) { taskRegistry.cancel(task.id) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section("Developer Activity") {
                Text("Recent task timings and UI scheduling delays. Traces contain metadata only—never prompts, responses, tool arguments, paths, or secrets.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                if performanceMonitor.samples.isEmpty {
                    Text("No activity recorded yet.").foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(Array(performanceMonitor.samples.prefix(30))) { sample in
                        HStack(spacing: 10) {
                            Image(systemName: sample.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(sample.succeeded ? .green : .orange)
                            Text(sample.startedAt, style: .time)
                                .limaFont(.caption.monospacedDigit())
                                .foregroundStyle(LimaTheme.textSecondary)
                            Text(sample.operation).lineLimit(1)
                            Spacer()
                            Text("\(sample.milliseconds) ms")
                                .limaFont(.caption.monospacedDigit())
                                .foregroundStyle(LimaTheme.textSecondary)
                        }
                    }
                }
                HStack {
                    Button("Copy Trace") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(performanceMonitor.redactedTrace(), forType: .string)
                        developerTraceMessage = "Copied metadata-only trace."
                    }
                    Button("Export Trace…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "Lima-Activity-Trace.txt"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        do {
                            try performanceMonitor.redactedTrace().write(to: url, atomically: true, encoding: .utf8)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                            developerTraceMessage = "Exported metadata-only trace."
                        } catch { developerTraceMessage = error.localizedDescription }
                    }
                }
                if let developerTraceMessage {
                    Text(developerTraceMessage).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                }
            }

            Section("Recent slow operations") {
                if runtime.recentSlowOperations.isEmpty {
                    Text("No operations over 1 second have been recorded.")
                        .foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(runtime.recentSlowOperations) { sample in
                        HStack {
                            Text(sample.operation)
                            Spacer()
                            Text("\(sample.milliseconds) ms")
                                .limaFont(.caption.monospacedDigit())
                                .foregroundStyle(sample.succeeded ? LimaTheme.textSecondary : .orange)
                        }
                    }
                }
                if !performanceMonitor.samples.isEmpty {
                    Button("Clear performance history") { performanceMonitor.clear() }
                }
            }

            Section("Today") {
                LabeledContent("Completed tasks", value: summary.completedToday.formatted())
                LabeledContent("Failed or cancelled", value: summary.failedToday.formatted())
                LabeledContent("Local processing time", value: durationLabel(summary.processingSecondsToday))
                LabeledContent("Characters processed", value: summary.inputCharactersToday.formatted())
                LabeledContent("Characters produced", value: summary.outputCharactersToday.formatted())
            }

            Section("Launcher learning") {
                LabeledContent("Recent commands", value: "\(viewModel.lastLearnedCommands().count)")
                Button("Reset Learned Ranking", role: .destructive) { viewModel.resetLearnedRanking() }
                    .help("Forget usage frequency, recency, and source-application ranking")
                Button("Reset Favorites") { CommandManager.shared.resetFavorites() }
            }

            Section("Command ranking controls") {
                Text("Manage pinned commands and learned ranking without opening the Action Panel.")
                    .foregroundStyle(LimaTheme.textSecondary)
                    .limaFont(.caption)
                ForEach(viewModel.commandDescriptors) { descriptor in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.title).limaFont(.callout.weight(.medium))
                            Text(descriptor.subtitle).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                        }
                        Spacer()
                        Button {
                            CommandManager.shared.toggleFavorite(descriptor.id)
                            viewModel.refreshForSettings()
                        } label: {
                            Label(CommandManager.shared.isFavorite(descriptor.id) ? "Pinned" : "Pin", systemImage: CommandManager.shared.isFavorite(descriptor.id) ? "pin.fill" : "pin")
                        }
                        .buttonStyle(.bordered)
                        Button("Forget") { viewModel.forgetLearnedRanking(descriptor.id) }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.lastLearnedCommands(limit: 100).contains(descriptor.id))
                    }
                }
            }

            Section("Command aliases") {
                Text("Aliases are local and are ranked below an exact command title.")
                    .foregroundStyle(LimaTheme.textSecondary)
                    .limaFont(.caption)
                ForEach(viewModel.commandDescriptors) { descriptor in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(descriptor.title).limaFont(.callout.weight(.medium))
                        HStack {
                            TextField("comma-separated aliases", text: Binding(
                                get: { aliasDrafts[descriptor.id] ?? viewModel.aliases(for: descriptor.id).joined(separator: ", ") },
                                set: { aliasDrafts[descriptor.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                viewModel.setAliases((aliasDrafts[descriptor.id] ?? "").split(separator: ",").map(String.init), for: descriptor.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            MacroComposerView(viewModel: viewModel)

            Section("Launcher latency budgets") {
                ForEach(Array(latencySamples.enumerated()), id: \.offset) { _, sample in
                    HStack {
                        Text(sample.operation)
                        Spacer()
                        Text("\(sample.milliseconds, specifier: "%.1f") ms / \(sample.budget, specifier: "%.0f") ms")
                            .foregroundStyle(sample.withinBudget ? Color.secondary : Color.orange)
                    }
                }
                if LauncherPerformanceDiagnostics.shared.samples.isEmpty {
                    Text("No launcher measurements recorded yet.")
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Button("Clear Diagnostics") { LauncherPerformanceDiagnostics.shared.clear() }
            }

            Section("Recent work") {
                if usageMonitor.events.isEmpty {
                    Text("Completed dictation, grammar, and executable-extension tasks will appear here.")
                        .foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(usageMonitor.events.prefix(20)) { event in
                        HStack(spacing: 10) {
                            Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(event.succeeded ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.operation).limaFont(.callout.weight(.medium))
                                Text("\(event.model ?? event.category.rawValue) · \(event.performance) · \(event.threads) threads · \(durationLabel(event.duration))")
                                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                            }
                            Spacer()
                            Text(event.startedAt, style: .relative).limaFont(.caption2).foregroundStyle(LimaTheme.textTertiary)
                        }
                    }
                }
                HStack {
                    Button("Reveal Log", action: usageMonitor.revealLog)
                        .disabled(usageMonitor.events.isEmpty)
                    Button("Clear Log…", role: .destructive) { confirmUsageClear = true }
                        .disabled(usageMonitor.events.isEmpty)
                }
                Label("The log stays on this Mac and records task names, limits, duration, counts, and success—not selected text, note contents, or document data.", systemImage: "hand.raised.fill")
                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int(seconds) / 60
        let remaining = Int(seconds) % 60
        return "\(minutes)m \(remaining)s"
    }

    @ViewBuilder
    private func accessoryMouseBindingRow(button: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Mouse button \(button + 1)", systemImage: "computermouse")
                    .limaFont(.callout.weight(.medium))
                Spacer()
                Picker("Mouse button \(button + 1) binding type", selection: accessoryMouseBindingKind(for: button)) {
                    ForEach(AccessoryMouseBindingKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            switch settings.accessoryMouseBinding(for: button) {
            case .none:
                EmptyView()
            case .action:
                Picker("Lima or macOS action", selection: accessoryMouseActionBinding(for: button)) {
                    ForEach(AccessoryMouseAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            case .shortcut:
                HStack {
                    Text("Shortcut")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                    Spacer()
                    ShortcutRecorder(
                        shortcut: accessoryMouseShortcutBinding(for: button),
                        label: "Mouse button \(button + 1) keyboard shortcut"
                    )
                    .frame(width: 145, height: 28)
                    Button("Clear") {
                        settings.setAccessoryMouseBinding(.none, for: button)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LimaTheme.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func accessoryMouseBindingKind(for button: Int) -> Binding<AccessoryMouseBindingKind> {
        Binding(
            get: { settings.accessoryMouseBinding(for: button).kind },
            set: { kind in
                let current = settings.accessoryMouseBinding(for: button)
                switch kind {
                case .none:
                    settings.setAccessoryMouseBinding(.none, for: button)
                case .action:
                    if case .action(let action) = current {
                        settings.setAccessoryMouseBinding(.action(action), for: button)
                    } else {
                        settings.setAccessoryMouseBinding(.action(.launcher), for: button)
                    }
                case .shortcut:
                    if case .shortcut(let shortcut) = current {
                        settings.setAccessoryMouseBinding(.shortcut(shortcut), for: button)
                    } else {
                        settings.setAccessoryMouseBinding(.shortcut(""), for: button)
                    }
                }
            }
        )
    }

    private func accessoryMouseActionBinding(for button: Int) -> Binding<AccessoryMouseAction> {
        Binding(
            get: {
                if case .action(let action) = settings.accessoryMouseBinding(for: button) {
                    return action
                }
                return .none
            },
            set: { action in
                settings.setAccessoryMouseBinding(action == .none ? .none : .action(action), for: button)
            }
        )
    }

    private func accessoryMouseShortcutBinding(for button: Int) -> Binding<String> {
        Binding(
            get: { settings.accessoryMouseShortcut(for: button) },
            set: { settings.setAccessoryMouseShortcut($0, for: button) }
        )
    }

    private var shortcutsTab: some View {
        Form {
            Section("Global hotkeys") {
                PrimaryShortcutRow(
                    title: "Open Search",
                    symbol: "magnifyingglass",
                    enabled: $settings.activationHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.activation")
                )
                PrimaryShortcutRow(
                    title: "Notes",
                    symbol: "note.text",
                    enabled: $settings.notesHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.notes")
                )
                PrimaryShortcutRow(
                    title: "Quick Note",
                    symbol: "rectangle.righthalf.inset.filled",
                    enabled: $settings.quickNoteHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.quick-note")
                )
                PrimaryShortcutRow(
                    title: "Dictation",
                    symbol: "mic.fill",
                    enabled: $settings.dictationHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.dictation")
                )
                PrimaryShortcutRow(
                    title: "Dock Notes Left",
                    symbol: "rectangle.lefthalf.inset.filled",
                    enabled: $settings.notesDockLeftHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.notes-dock-left")
                )
                PrimaryShortcutRow(
                    title: "Dock Notes Right",
                    symbol: "rectangle.righthalf.inset.filled",
                    enabled: $settings.notesDockRightHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.notes-dock-right")
                )
                PrimaryShortcutRow(
                    title: "Terminal",
                    symbol: "terminal.fill",
                    enabled: $settings.terminalHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.terminal")
                )
                PrimaryShortcutRow(
                    title: "Add Selection to Shelf",
                    symbol: "text.badge.plus",
                    enabled: $settings.contextShelfCaptureHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.context-shelf.capture-selection")
                )
            }

            Section("Shortcut lookup") {
                HStack {
                    Label("Press shortcut…", systemImage: "keyboard")
                    Spacer()
                    ShortcutRecorder(shortcut: $shortcutLookupDraft, label: "Shortcut to look up")
                        .frame(width: 132, height: 28)
                }
                let owners = commandManager.shortcutRegistry.owners(of: shortcutLookupDraft)
                if owners.isEmpty {
                    Label(
                        shortcutLookupDraft.isEmpty ? "Record a shortcut to find its Lima assignment." : "No Lima command uses this shortcut.",
                        systemImage: shortcutLookupDraft.isEmpty ? "info.circle" : "checkmark.circle"
                    )
                    .foregroundStyle(LimaTheme.textSecondary)
                    .limaFont(.caption)
                } else {
                    ForEach(owners) { owner in
                        LabeledContent("Assigned to", value: owner.title)
                    }
                }
            }

            Section("Accessory mouse buttons") {
                Text("Bind extra mouse buttons to any Lima action or record a keyboard shortcut, like Mac Mouse Fix. The shortcut is sent to the app that is focused when you press the mouse button.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                ForEach(3...8, id: \.self) { button in
                    accessoryMouseBindingRow(button: button)
                }
            }

            Section("Command audit") {
                Text("Command enablement and shortcuts are independent. Use the recorder on any row to assign a shortcut.")
                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                ForEach(viewModel.commandDescriptors) { descriptor in
                    HStack(spacing: 9) {
                        Image(systemName: "command.circle").foregroundStyle(settings.accentTheme.readablePrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.title).limaFont(.callout.weight(.medium))
                            Text(descriptor.subtitle).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                        }
                        Spacer()
                        Toggle("Enable \(descriptor.title)", isOn: Binding(
                            get: { CommandManager.shared.isEnabled(descriptor.id) },
                            set: { CommandManager.shared.setEnabled($0, for: descriptor.id) }
                        )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                if !CommandManager.shared.conflictMessages.isEmpty {
                    ForEach(CommandManager.shared.conflictMessages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).limaFont(.caption)
                    }
                } else {
                    Label("No Lima shortcut conflicts detected.", systemImage: "checkmark.circle").foregroundStyle(LimaTheme.textSecondary).limaFont(.caption)
                }
            }

            Section("Dictation input") {
                Picker("Dictation engine", selection: $settings.dictationEngine) {
                    ForEach(DictationEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Text(settings.dictationEngine.detail)
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                if settings.dictationEngine == .openAICloud {
                    Text(aiChatModel.credentials.hasAPIKey(for: .openAI)
                         ? "OpenAI API key is available in Keychain."
                         : "Add an OpenAI API key in Settings → AI before recording.")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                if settings.dictationEngine == .localWhisper {
                    Picker("Whisper compute", selection: $settings.dictationComputeMode) {
                        ForEach(DictationComputeMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var privacyTab: some View {
        Form {
            Section("Permission Center") {
                ForEach(PermissionCenter.PermissionID.allCases) { permission in
                    HStack {
                        Text(permission.title)
                        Spacer()
                        Text(permissionCenter.statuses[permission]?.rawValue ?? "Checking…").foregroundStyle(LimaTheme.textSecondary)
                        Button("Review") { permissionCenter.request(permission) }
                    }
                }
            }
            Section("Backups and diagnostics") {
                Button("Export Backup…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "Lima-Backup.json"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { _ = try backups.exportBackup(to: url) } catch { backups.report(error) }
                }
                Button("Import Backup…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    do { try backups.importBackup(from: url) } catch { backups.report(error) }
                }
                Button("Export Diagnostics…") {
                    do { let url = try DiagnosticsService.shared.export(); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    catch { SettingsStore.shared.lastError = error.localizedDescription }
                }
                if let error = backups.lastError { Text(error).foregroundStyle(.orange) }
            }
            Section("Persistence") {
                if let error = settings.lastError { Text(error).foregroundStyle(.orange) }
                Text("Notes, dictation, clipboard, settings, Lima's single Terminal shell, workflows, and Workspace state use private atomic storage with recovery copies.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
        .onAppear { permissionCenter.refresh() }
    }

    private var clipboardTab: some View {
        Form {
            Section("Local clipboard history") {
                Toggle("Remember copied text", isOn: $settings.clipboardEnabled)
                Stepper("Keep up to \(settings.clipboardLimit) items", value: $settings.clipboardLimit, in: 10...500, step: 10)
                Text("Off by default. When enabled, Lima checks the macOS clipboard and stores text only in ~/Library/Application Support/Lima. Nothing is sent over the network.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                if #available(macOS 15.4, *) {
                    Text("macOS clipboard permission: \(pasteboardAccessDescription())")
                        .limaFont(.caption)
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Button("Clear Clipboard History", role: .destructive) {
                    confirmClipboardClear = true
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
        .alert("Clear Clipboard History?", isPresented: $confirmClipboardClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { viewModel.clipboard.clear() }
        } message: {
            Text("This permanently removes every item Lima has saved from the clipboard.")
        }
    }

    private var secretsTab: some View {
        Form {
            Section("Keychain secrets") {
                Text("Values are stored in the macOS Keychain. Lima saves only names, kinds, and opaque references in workspace data; values are never shown in this list.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                if secrets.references.isEmpty {
                    Text("No secrets saved.").foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(secrets.references) { reference in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reference.name).limaFont(.callout.weight(.medium))
                                Text(reference.kind.title).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editingSecretID = reference.id
                                secretName = reference.name
                                secretKind = reference.kind
                                secretValue = ""
                            }
                            Button("Delete", role: .destructive) { secrets.delete(reference) }
                        }
                    }
                }
            }
            Section(editingSecretID == nil ? "Add secret" : "Replace secret") {
                TextField("Name", text: $secretName)
                Picker("Kind", selection: $secretKind) {
                    ForEach(LimaSecretKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
                }
                SecureField("Value", text: $secretValue)
                Text("Editing requires entering the value again; existing secret values are not revealed.")
                    .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                HStack {
                    Button(editingSecretID == nil ? "Add to Keychain" : "Replace value") {
                        do {
                            _ = try secrets.save(secretValue, name: secretName, kind: secretKind, id: editingSecretID)
                            secretName = ""; secretValue = ""; editingSecretID = nil
                        } catch { settings.lastError = error.localizedDescription }
                    }
                    .disabled(secretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secretValue.isEmpty)
                    if editingSecretID != nil {
                        Button("Cancel") { secretName = ""; secretValue = ""; editingSecretID = nil }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var commandCenterTab: some View {
        CommandCenterView(
            viewModel: viewModel,
            settings: settings,
            commandManager: commandManager,
            extensionStoreModel: extensionStoreModel,
            reloadExtensions: reloadExtensions,
            makeShortcutBinding: { shortcutBinding(for: $0) }
        )
    }

    private var extensionGroups: [SettingsExtensionGroup] {
        Dictionary(grouping: viewModel.extensionCommands, by: \.settingsPackKey)
            .map { key, commands in
                let representative = commands.first
                return SettingsExtensionGroup(
                    id: key,
                    name: representative?.pack ?? representative?.extensionName ?? key,
                    category: representative?.category ?? "Extensions",
                    provenance: representative?.provenanceLabel ?? "User extension",
                    commands: commands.sorted {
                        $0.command.title.localizedStandardCompare($1.command.title) == .orderedAscending
                    }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }


    private var generalTab: some View {
        Form {
            Section {
                PrimaryShortcutRow(
                    title: "Open Search",
                    symbol: "magnifyingglass",
                    enabled: $settings.activationHotkeyEnabled,
                    shortcut: shortcutBinding(for: "builtin.activation")
                )
                Text("Click the shortcut field, then press the keys you want to use from any app. If macOS already uses that shortcut, change the macOS shortcut first.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            } header: {
                Label("Search shortcut", systemImage: "magnifyingglass").limaFont(.headline)
            }

            Section {
                Toggle(isOn: Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch Lima at login")
                        Text("Keep the workspace ready when you start this Mac.")
                            .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                    }
                }.toggleStyle(.switch)
                if let error = settings.lastError {
                    Text(error).limaFont(.caption).foregroundStyle(LimaTheme.warning)
                }
                Button("Configure commands and keyboard shortcuts") { selectedSection = .commands }
                    .buttonStyle(.borderless)
            } header: {
                Label("App preferences", systemImage: "gearshape").limaFont(.headline)
            }

            Section {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                AccentThemePicker(selection: $settings.accentTheme)
                Picker("Interface contrast", selection: $settings.contrastMode) {
                    ForEach(AppContrastMode.allCases) { Text($0.title).tag($0) }
                }
                Button("All appearance settings") { selectedSection = .appearance }
                    .buttonStyle(.borderless)
            } header: {
                Label("Appearance", systemImage: "paintpalette").limaFont(.headline)
            }

            Section {
                Picker("Editor width", selection: $settings.notesContentWidth) {
                    ForEach(NotesContentWidth.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show note metadata", isOn: $settings.notesShowMetadata)
                Toggle("Check spelling and grammar inline", isOn: $settings.inlineGrammarCheckingEnabled)
                Text("Notes are stored locally and saved as you type.")
                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
            } header: {
                Label("Notes", systemImage: "note.text").limaFont(.headline)
            }

            Section("Software Updates") {
                Text("Lima \(updateService.currentVersion) · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                    .limaFont(.caption.weight(.medium))
                Text(updateService.statusText)
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                HStack {
                    Button("Check for Updates") { updateService.checkForUpdates(manual: true) }
                        .disabled(updateService.isBusy || updateService.isInstalling)
                    Button("View Releases") { NSWorkspace.shared.open(UpdateService.repositoryURL) }
                }
                if updateService.isBusy && !updateService.isInstalling {
                    ProgressView().controlSize(.small)
                }
                if updateService.isInstalling {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: updateService.installationProgress)
                            .tint(SettingsColors.readableIndigo)
                        Text("\(Int(updateService.installationProgress * 100))% · \(updateService.installationStage)")
                            .limaFont(.caption2.weight(.medium))
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                }
            }

            Section(editingSecretID == nil ? "Add secret" : "Replace secret") {
                TextField("Name", text: $secretName)
                Picker("Kind", selection: $secretKind) {
                    ForEach(LimaSecretKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
                }
                SecureField("Value", text: $secretValue)
                Text("Editing requires entering the value again; existing secret values are not revealed.")
                    .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                HStack {
                    Button(editingSecretID == nil ? "Add to Keychain" : "Replace value") {
                        do {
                            _ = try secrets.save(secretValue, name: secretName, kind: secretKind, id: editingSecretID)
                            secretName = ""; secretValue = ""; editingSecretID = nil
                        } catch { settings.lastError = error.localizedDescription }
                    }
                    .disabled(secretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secretValue.isEmpty)
                    if editingSecretID != nil {
                        Button("Cancel") { secretName = ""; secretValue = ""; editingSecretID = nil }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.regular)
        .onAppear { if !LimaTestEnvironment.isEnabled { settings.refreshLaunchAtLogin() } }
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .limaFont(.system(size: 56, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(settings.accentTheme.readablePrimary)
            Text("Lima").limaFont(.title.bold())
            Text("A fast macOS command launcher built around local-first workflows and explicit integrations.")
                .foregroundStyle(LimaTheme.textSecondary)
            Text("Local features stay on this Mac. Features configured with external providers may send only the data required for that action.")
                .limaFont(.callout.weight(.medium))
            Text("Version \(updateService.currentVersion) · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textTertiary)
            Text(updateService.statusText)
                .limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if updateService.isInstalling {
                VStack(spacing: 7) {
                    ProgressView(value: updateService.installationProgress)
                        .tint(SettingsColors.readableIndigo)
                    Text("\(Int(updateService.installationProgress * 100))% · \(updateService.installationStage)")
                        .limaFont(.caption2.weight(.medium))
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                .frame(maxWidth: 420)
            }
            HStack {
                Button("Check for Updates") { updateService.checkForUpdates(manual: true) }
                    .disabled(updateService.isBusy || updateService.isInstalling)
                Button("View on GitHub") { NSWorkspace.shared.open(UpdateService.repositoryURL) }
            }
            if updateService.isBusy && !updateService.isInstalling { ProgressView().controlSize(.small) }
            DisclosureGroup("Update details") {
                Text("Verified prebuilt updates replace this app in place after confirmation. No local compilation is required.")
                    .limaFont(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Text("~/Library/Application Support/Lima/Updates/update.log")
                    .limaFont(.caption2.monospaced())
                    .foregroundStyle(LimaTheme.textTertiary)
                Button("Reveal running app in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Text(Bundle.main.bundleURL.path).limaFont(.caption2.monospaced()).textSelection(.enabled)
            }
            .frame(maxWidth: 470)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @available(macOS 15.4, *)
    private func pasteboardAccessDescription() -> String {
        switch NSPasteboard.general.accessBehavior.rawValue {
        case 0: return "Ask when first needed"
        case 1: return "Ask before access"
        case 2: return "Always allow"
        case 3: return "Always deny"
        default: return "Managed by macOS"
        }
    }
}


private struct SettingsCompactStatus: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(value == "Allowed" || value == "Ready" ? LimaColors.success : LimaColors.warning)
                .frame(width: 5, height: 5)
            Text(title)
                .limaFont(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 3)
            Text(value)
                .limaFont(.system(size: 9.5, weight: .medium))
                .foregroundStyle(LimaTheme.textSecondary)
                .lineLimit(1)
        }
    }
}

private struct AccentThemePicker: View {
    @Binding var selection: AppAccentTheme

    private let columns = [GridItem(.adaptive(minimum: 30, maximum: 40), spacing: 7)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Accent theme")
                    .limaFont(.callout.weight(.medium))
                Spacer()
                Text(selection.title)
                    .limaFont(.caption.weight(.semibold))
                    .foregroundStyle(SettingsStore.shared.accentTheme.readablePrimary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                ForEach(AppAccentTheme.allCases) { theme in
                    Button { selection = theme } label: {
                        PrismaticPanelShape(cut: 5)
                            .fill(theme.gradient)
                            .frame(width: 30, height: 30)
                            .overlay(
                                PrismaticPanelShape(cut: 5)
                                    .stroke(selection == theme ? LimaTheme.borderStrong : LimaTheme.borderSubtle, lineWidth: selection == theme ? LimaDesign.focusWidth : LimaDesign.borderWidth)
                            )
                            .background(PrismaticPanelShape(cut: 6).fill(selection == theme ? theme.primary.opacity(0.20) : .clear))
                            .shadow(color: selection == theme ? theme.primary.opacity(0.22) : .clear, radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help(theme.title)
                    .accessibilityLabel(theme.title)
                    .accessibilityValue(selection == theme ? "Selected" : "")
                }
            }
        }
    }
}

private struct PrimaryShortcutRow: View {
    let title: String
    let symbol: String
    @Binding var enabled: Bool
    @Binding var shortcut: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(enabled ? SettingsStore.shared.accentTheme.readablePrimary : .secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .limaFont(.callout.weight(.medium))
            Spacer()
            Toggle("Enable \(title) hotkey", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            ShortcutRecorder(shortcut: $shortcut, label: "\(title) shortcut")
                .frame(width: 132, height: 28)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.46)
        }
    }
}

private struct ExtensionShortcutRow: View {
    @ObservedObject var settings: SettingsStore
    let loaded: LoadedExtensionCommand

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: loaded.command.icon ?? "puzzlepiece.extension.fill")
                .foregroundStyle(settings.accentTheme.readablePrimary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(loaded.command.title)
                .limaFont(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
            Toggle(isOn: Binding(
                get: { settings.isHotkeyEnabled(loaded) },
                set: { settings.setHotkeyEnabled($0, for: loaded) }
            )) {
                Image(systemName: "command")
                    .limaFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(LimaTheme.textSecondary)
                    .accessibilityHidden(true)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .accessibilityLabel("Enable \(loaded.command.title) hotkey")
            ShortcutRecorder(
                shortcut: Binding(
                    get: { settings.effectiveShortcut(for: loaded) ?? "" },
                    set: { settings.setShortcut($0, for: loaded) }
                ),
                label: "\(loaded.command.title) shortcut"
            )
            .frame(width: 106, height: 28)
            .disabled(!settings.isHotkeyEnabled(loaded))

            Menu {
                Button("Clear Shortcut") { settings.setShortcut(nil, for: loaded) }
                    .disabled(settings.effectiveShortcut(for: loaded) == nil)
                Button("Use Default") { settings.resetShortcut(for: loaded) }
                    .disabled(!settings.hasShortcutOverride(for: loaded))
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: String
    var label = "Activation shortcut"

    func makeCoordinator() -> Coordinator { Coordinator(shortcut: $shortcut) }

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onChange = { context.coordinator.shortcut.wrappedValue = $0 }
        view.shortcut = shortcut
        view.accessibilityLabelText = label
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {
        nsView.shortcut = shortcut
        nsView.accessibilityLabelText = label
    }

    final class Coordinator {
        var shortcut: Binding<String>
        init(shortcut: Binding<String>) { self.shortcut = shortcut }
    }
}

final class ShortcutCaptureView: NSView {
    var shortcut = "" {
        didSet {
            needsDisplay = true
            updateAccessibilityValue()
        }
    }
    var onChange: ((String) -> Void)?
    var accessibilityLabelText = "Activation shortcut" {
        didSet { setAccessibilityLabel(accessibilityLabelText) }
    }
    private var recording = false {
        didSet {
            if !recording { lastCommandRelease = nil }
            needsDisplay = true
            updateAccessibilityValue()
        }
    }
    private var lastCommandRelease: TimeInterval?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 145, height: 28) }

    override func accessibilityPerformPress() -> Bool {
        recording = true
        window?.makeFirstResponder(self)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Set<ShortcutSpec.Modifier>()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard !modifiers.isEmpty, let key = Self.keyName(for: event) else {
            NSSound.beep()
            return
        }
        // Persist the physical virtual key code so custom shortcuts keep working
        // on non-US keyboard layouts. The suffix preserves a friendly label.
        let physicalKey = "kc\(event.keyCode):\(key)"
        let value = ShortcutSpec(modifiers: modifiers, key: physicalKey).storageString
        shortcut = value
        onChange?(value)
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording, event.keyCode == 54 || event.keyCode == 55 else {
            super.flagsChanged(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return }
        let now = event.timestamp
        if let previous = lastCommandRelease, now - previous <= 0.55 {
            let value = ShortcutSpec(modifiers: [.command], key: "command").storageString
            shortcut = value
            onChange?(value)
            recording = false
            window?.makeFirstResponder(nil)
        } else {
            lastCommandRelease = now
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        let accent = SettingsStore.shared.accentTheme.nsPrimary
        (recording ? accent.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? accent : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let value = recording
            ? "Press shortcut…"
            : (shortcut.isEmpty ? "No shortcut" : (ShortcutSpec(string: shortcut)?.displayString ?? shortcut))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let string = NSAttributedString(string: value, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabelText)
        setAccessibilityHelp("Press to record a new global shortcut.")
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        let value = recording
            ? "Recording. Press a modifier and key, or tap Command twice."
            : (shortcut.isEmpty ? "No shortcut" : (ShortcutSpec(string: shortcut)?.displayString ?? shortcut))
        setAccessibilityValue(value)
    }

    private static func keyName(for event: NSEvent) -> String? {
        let special: [UInt16: String] = [
            36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape",
            123: "left", 124: "right", 125: "down", 126: "up",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
            98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"
        ]
        if let value = special[event.keyCode] { return value }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1 else { return nil }
        return characters
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsStore: SettingsStore

    init(settings: SettingsStore, viewModel: LauncherViewModel, aiChatModel: AIChatViewModel, updateService: UpdateService, reloadExtensions: @escaping () -> Void, openGrammarDebugger: @escaping () -> Void, extensionStoreModel: ExtensionStoreModel) {
        self.settingsStore = settings
        let view = SettingsView(settings: settings, viewModel: viewModel, aiChatModel: aiChatModel, updateService: updateService, reloadExtensions: reloadExtensions, openGrammarDebugger: openGrammarDebugger, extensionStoreModel: extensionStoreModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: "Lima Settings",
            accessibilityLabel: "Lima Settings",
            minSize: NSSize(width: 760, height: 540),
            movableByBackground: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: view))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        settingsStore.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
    }
}


@MainActor
private struct SimpleWritingSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Binding var apiKey: String
    @Binding var shortcut: String
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Fix Writing") {
                Toggle("Enable Fix Writing", isOn: Binding(get: { settings.grammarEngineEnhanced }, set: { settings.grammarEngineEnhanced = $0 }))
                Picker("Engine", selection: Binding(get: { settings.grammarEngineMode }, set: { settings.grammarEngineMode = $0 })) {
                    Text("AI correction").tag(GrammarEngineMode.externalAPI)
                    Text("Harper (local)").tag(GrammarEngineMode.local)
                }.pickerStyle(.segmented)
                Toggle("Use Harper if AI is unavailable", isOn: Binding(get: { settings.grammarFallbackToLocal }, set: { settings.grammarFallbackToLocal = $0 }))
            }
            Section("AI connection") {
                Picker("Provider", selection: Binding(get: { settings.developerGrammarProvider }, set: { settings.selectDeveloperGrammarProvider($0); apiKey = ""; message = nil })) {
                    ForEach(AIProvider.writingProviders) { Text($0.title).tag($0) }
                }
                SecureField("API key", text: $apiKey)
                HStack {
                    Label(settings.enhancedGrammarAPIKeyStored ? "API key stored in Keychain" : "No API key stored", systemImage: settings.enhancedGrammarAPIKeyStored ? "checkmark.circle.fill" : "key")
                        .foregroundStyle(settings.enhancedGrammarAPIKeyStored ? .green : .secondary)
                    Spacer()
                    Button("Save") {
                        do { try settings.saveDeveloperGrammarAPIKey(apiKey); apiKey = ""; message = "Saved securely in Keychain." }
                        catch { message = error.localizedDescription }
                    }.disabled(apiKey.isEmpty)
                }
                Picker("Model", selection: Binding(get: { settings.developerGrammarModel }, set: { settings.developerGrammarModel = $0 })) {
                    ForEach(settings.developerGrammarProvider.modelOptions, id: \.id) { option in Text(option.title).tag(option.id) }
                    if !settings.developerGrammarProvider.modelOptions.contains(where: { $0.id == settings.developerGrammarModel }) {
                        Text(settings.developerGrammarModel.isEmpty ? "Choose a model" : settings.developerGrammarModel).tag(settings.developerGrammarModel)
                    }
                }
                TextField("Custom model ID", text: $settings.developerGrammarModel)
                TextField("Base URL", text: $settings.developerGrammarBaseURL)
                Text("Use HTTPS, or HTTP for a loopback server. Compatible servers may omit the API key. Keys are shared with AI Chat; models and endpoints are separate. Connection testing and ensemble controls are in Writing Advanced.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                Button("Remove Shared Key", role: .destructive) { confirmRemove = true }
                    .disabled(!settings.enhancedGrammarAPIKeyStored)
                Text("Only the text being corrected is sent to the configured provider. Harper remains local.")
                    .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                if let message { Text(message).font(.caption).foregroundStyle(LimaTheme.textSecondary) }
            }
            Section("Shortcut") {
                PrimaryShortcutRow(title: "Fix Writing", symbol: "text.badge.checkmark", enabled: Binding(get: { settings.stealthGrammarEnabled }, set: { settings.stealthGrammarEnabled = $0 }), shortcut: $shortcut)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).controlSize(.small)
        .onDisappear { apiKey = "" }
        .alert("Remove shared provider key?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                do { try settings.saveDeveloperGrammarAPIKey(""); apiKey = ""; message = nil }
                catch { message = error.localizedDescription }
            }
        } message: { Text("This removes the provider key used by both AI Chat and Writing.") }
    }
}
