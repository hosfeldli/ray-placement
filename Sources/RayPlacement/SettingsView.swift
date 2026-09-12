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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case writing
    case clipboard
    case extensions
    case privacy
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts & Input"
        case .writing: return "Writing & Dictation"
        case .clipboard: return "Clipboard"
        case .extensions: return "Extensions"
        case .privacy: return "Privacy & Permissions"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .writing: return "wand.and.stars"
        case .clipboard: return "clipboard.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .privacy: return "checkmark.shield.fill"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        }
    }

    var searchTerms: [String] {
        switch self {
        case .general: return ["general", "appearance", "accent", "density", "text size", "launch at login", "theme"]
        case .shortcuts: return ["shortcuts", "input", "launcher", "notes", "quick note", "dictation", "terminal", "mouse", "hotkey"]
        case .writing: return ["writing", "dictation", "grammar", "engine", "local", "enhanced", "provider", "api key", "preserved terms", "stealth", "whisper", "transcription"]
        case .clipboard: return ["clipboard", "history", "monitoring", "clear", "limit"]
        case .extensions: return ["extensions", "packs", "permissions", "commands", "shortcuts"]
        case .privacy: return ["privacy", "permissions", "accessibility", "microphone", "speech recognition", "security", "backup", "diagnostics"]
        case .advanced: return ["advanced", "performance", "whisper compute", "usage", "debugging", "secrets", "keychain", "model", "base url"]
        case .about: return ["about", "updates", "version", "support"]
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
    @ObservedObject var updateService: UpdateService
    @ObservedObject private var usageMonitor = UsageMonitor.shared
    @ObservedObject private var commandManager = CommandManager.shared
    @ObservedObject private var workspaceProfiles = WorkspaceProfileStore.shared
    @ObservedObject private var permissionCenter = PermissionCenter.shared
    @ObservedObject private var backups = DataBackupCoordinator.shared
    @ObservedObject private var secrets = LimaSecretStore.shared
    @State private var secretName = ""
    @State private var secretValue = ""
    @State private var secretKind: LimaSecretKind = .localSecret
    @State private var editingSecretID: UUID?
    @State private var confirmClipboardClear = false
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var selectedSection: SettingsSection = .general
    @State private var settingsSearchQuery = ""
    @State private var advancedSubsection = 0
    @State private var confirmUsageClear = false
    @State private var commandProfileName = ""
    @State private var workspaceProfileName = ""
    @State private var grammarAPIKey = ""
    @State private var grammarConnectionMessage: String?
    @State private var isTestingGrammarConnection = false
    @State private var grammarCompatibilityMessage: String?
    @State private var isTestingGrammarCompatibility = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reloadExtensions: () -> Void

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            HStack(spacing: LimaDesign.panelGap) {
                settingsSidebar
                VStack(spacing: 0) {
                    HStack {
                        LimaToolbarTitle(
                            symbol: selectedSection.symbol,
                            title: selectedSection.title,
                            subtitle: "Lima preferences"
                        )
                        Spacer()
                    }
                    .padding(.horizontal, LimaDesign.toolbarPadding)
                    .frame(height: LimaDesign.sectionHeaderHeight)
                    GlassHairline()
                    selectedContent
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.992)))
                }
                .limaNativeSurface(fill: LimaColors.raisedSurface, radius: LimaRadius.window, border: LimaColors.border)
            }
            .padding(LimaDesign.windowPadding)
        }
        .frame(minWidth: 820, idealWidth: 820, minHeight: 590, idealHeight: 590)
        .tint(settings.accentTheme.readablePrimary)
        .limaAnimation(LimaDesign.spring(0.30), value: selectedSection)
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
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    PrismaticPanelShape(cut: 7)
                        .fill(SettingsColors.heroGradient)
                    Image(systemName: "sparkle.magnifyingglass")
                        .limaFont(.system(size: 14, weight: .bold))
                        .foregroundStyle(settings.accentTheme.onGradient)
                }
                .frame(width: 30, height: 30)
                .overlay(PrismaticPanelShape(cut: 7).stroke(LimaColors.primaryText.opacity(0.34), lineWidth: LimaDesign.borderWidth))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lima").limaFont(.system(size: 13.5, weight: .semibold))
                    Text("Settings").limaFont(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .semibold))
                TextField("Search settings", text: $settingsSearchQuery)
                    .textFieldStyle(.plain)
                    .limaFont(.system(size: 12.5))
                if !settingsSearchQuery.isEmpty {
                    Button { settingsSearchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LimaRadius.control, style: .continuous).stroke(LimaColors.border, lineWidth: LimaDesign.borderWidth))
            .padding(.horizontal, 9)
            .padding(.bottom, 10)

            if settingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sidebarGroup("GENERAL", sections: [.general, .shortcuts])
                sidebarGroup("FEATURES", sections: [.writing, .clipboard, .extensions])
                sidebarGroup("SYSTEM", sections: [.privacy, .advanced, .about])
            } else if filteredSections.isEmpty {
                Text("No matching settings")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            } else {
                Text("RESULTS")
                    .limaFont(.system(size: 9, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                ForEach(filteredSections) { settingsRow($0) }
            }

            Spacer(minLength: 10)
            settingsStatusSummary
                .padding(.horizontal, 11)
                .padding(.bottom, 11)
        }
        .frame(width: 204)
        .limaNativeSurface(fill: LimaColors.sidebarBackground, radius: LimaRadius.window, border: LimaColors.border)
    }

    private var filteredSections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.matches(settingsSearchQuery) }
    }

    @ViewBuilder
    private func sidebarGroup(_ title: String, sections: [SettingsSection]) -> some View {
        Text(title)
            .limaFont(.system(size: 9, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 3)
        ForEach(sections) { settingsRow($0) }
    }

    private func settingsRow(_ section: SettingsSection) -> some View {
        Button { selectedSection = section } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .limaFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selectedSection == section ? settings.accentTheme.readablePrimary : Color.secondary)
                    .frame(width: 21)
                Text(section.title)
                    .limaFont(.system(size: 12.5, weight: selectedSection == section ? .semibold : .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(selectedSection == section ? Color.primary : Color.primary.opacity(0.76))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .limaSelection(selectedSection == section, radius: LimaRadius.control)
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
                .foregroundStyle(.tertiary)
            SettingsCompactStatus(title: "Accessibility", value: compactPermission(.accessibility))
            SettingsCompactStatus(title: "Microphone", value: compactPermission(.microphone))
            SettingsCompactStatus(title: "Whisper", value: settings.dictationEngine == .localWhisper ? "Ready" : "Apple Speech")
            SettingsCompactStatus(
                title: "Correction Engine",
                value: settings.grammarEngineMode == .externalAPI
                    ? (settings.enhancedGrammarAPIKeyStored ? "External API · Connected" : "External API · Needs key")
                    : "Local"
            )
            SettingsCompactStatus(title: "Extensions", value: "\(viewModel.extensionCommands.count) enabled")
        }
        .padding(9)
        .background(LimaColors.recessedSurface, in: RoundedRectangle(cornerRadius: LimaRadius.card, style: .continuous))
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
        case .shortcuts: shortcutsTab
        case .writing: writingTab
        case .clipboard: clipboardTab
        case .extensions: extensionsTab
        case .privacy: privacyTab
        case .advanced: advancedDetails
        case .about: aboutTab
        }
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
                Picker("Transcription engine", selection: $settings.dictationEngine) {
                    ForEach(DictationEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Text(settings.dictationEngine.detail)
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                if settings.dictationEngine == .localWhisper {
                    Picker("Whisper compute", selection: $settings.dictationComputeMode) {
                        ForEach(DictationComputeMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }
                if settings.dictationEngine == .localWhisper {
                    Label("Semi-live · completed segments appear in the conversation while recording", systemImage: "waveform.badge.mic")
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
            .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)

            Picker("Correction engine", selection: $settings.grammarEngineMode) {
                Text("Local").tag(GrammarEngineMode.local)
                Text("External API").tag(GrammarEngineMode.externalAPI)
            }
            .pickerStyle(.segmented)
            if settings.grammarEngineMode == .externalAPI {
                Text("External API sends the checked text to the selected provider after protected spans are masked. It never falls back to Local on failure.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                Picker("Ensemble", selection: $settings.grammarEnsembleStrategy) {
                    ForEach(GrammarEnsembleStrategy.allCases) { strategy in
                        Text("\(strategy.title) · \(strategy.detail)").tag(strategy)
                    }
                }
                Text("Candidates use fixed Lima diversity seeds and different proofreader profiles. Balanced is the default.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
                if let grammarConnectionMessage {
                    Text(grammarConnectionMessage)
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Everything stays on this Mac", systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("Python spelling and Harper grammar run locally. No API key is required.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
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

    private var writingTab: some View {
        Form {
            grammarEngineSection
            Section("Local checker") {
                Toggle("Check Notes while typing", isOn: $settings.inlineGrammarCheckingEnabled)
                Text("Lima checks the current paragraph after a short pause. Code, links, protected terms, and Markdown structure are excluded.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                Label("Python spelling + Harper grammar", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Checks stay on this Mac. No text-generation model is installed or used.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Grammar") {
                Toggle("Enable keyboard grammar correction", isOn: $settings.stealthGrammarEnabled)
                PrimaryShortcutRow(
                    title: "Check and Correct Selected Text",
                    symbol: "wand.and.stars",
                    enabled: $settings.stealthGrammarEnabled,
                    shortcut: $settings.stealthGrammarShortcut
                )
                Text("Corrects highlighted text in place without opening a review. It uses the local checker by default and keeps URLs, proper nouns, acronyms, code-like text, and your preserved terms unchanged.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preserved terms") {
                Text("Enter product names, acronyms, and intentional spellings the checker should leave unchanged, separated by spaces, commas, or lines.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.writingInstructions)
                    .limaFont(.system(size: 12.5))
                    .frame(minHeight: 118)
                    .limaEditorSurface(cornerRadius: 5)
                    .accessibilityLabel("Words preserved by grammar correction")
                HStack {
                    Text("\(settings.writingInstructions.count.formatted()) / 4,000 characters")
                        .limaFont(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Restore Defaults") {
                        settings.resetWritingInstructions()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var usageTab: some View {
        let summary = usageMonitor.summary
        return Form {
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
                                    .limaFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(task.startedAt, style: .timer).limaFont(.caption.monospacedDigit())
                        }
                    }
                }
            }

            Section("Today") {
                LabeledContent("Completed tasks", value: summary.completedToday.formatted())
                LabeledContent("Failed or cancelled", value: summary.failedToday.formatted())
                LabeledContent("Local processing time", value: durationLabel(summary.processingSecondsToday))
                LabeledContent("Characters processed", value: summary.inputCharactersToday.formatted())
                LabeledContent("Characters produced", value: summary.outputCharactersToday.formatted())
            }

            Section("Recent work") {
                if usageMonitor.events.isEmpty {
                    Text("Completed dictation, grammar, and executable-extension tasks will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usageMonitor.events.prefix(20)) { event in
                        HStack(spacing: 10) {
                            Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(event.succeeded ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.operation).limaFont(.callout.weight(.medium))
                                Text("\(event.model ?? event.category.rawValue) · \(event.performance) · \(event.threads) threads · \(durationLabel(event.duration))")
                                    .limaFont(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(event.startedAt, style: .relative).limaFont(.caption2).foregroundStyle(.tertiary)
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
                    .limaFont(.caption).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                    title: "Launcher",
                    symbol: "command",
                    enabled: $settings.activationHotkeyEnabled,
                    shortcut: $settings.activationShortcut
                )
                PrimaryShortcutRow(
                    title: "Notes",
                    symbol: "note.text",
                    enabled: $settings.notesHotkeyEnabled,
                    shortcut: $settings.notesShortcut
                )
                PrimaryShortcutRow(
                    title: "Quick Note",
                    symbol: "rectangle.righthalf.inset.filled",
                    enabled: $settings.quickNoteHotkeyEnabled,
                    shortcut: $settings.quickNoteShortcut
                )
                PrimaryShortcutRow(
                    title: "Dictation",
                    symbol: "mic.fill",
                    enabled: $settings.dictationHotkeyEnabled,
                    shortcut: $settings.dictationShortcut
                )
                PrimaryShortcutRow(
                    title: "Dock Notes Left",
                    symbol: "rectangle.lefthalf.inset.filled",
                    enabled: $settings.notesDockLeftHotkeyEnabled,
                    shortcut: $settings.notesDockLeftShortcut
                )
                PrimaryShortcutRow(
                    title: "Dock Notes Right",
                    symbol: "rectangle.righthalf.inset.filled",
                    enabled: $settings.notesDockRightHotkeyEnabled,
                    shortcut: $settings.notesDockRightShortcut
                )
                PrimaryShortcutRow(
                    title: "Terminal",
                    symbol: "terminal.fill",
                    enabled: $settings.terminalHotkeyEnabled,
                    shortcut: $settings.terminalShortcut
                )
                PrimaryShortcutRow(
                    title: "Add Selection to Shelf",
                    symbol: "text.badge.plus",
                    enabled: $settings.contextShelfCaptureHotkeyEnabled,
                    shortcut: $settings.contextShelfCaptureShortcut
                )
            }

            Section("Accessory mouse buttons") {
                Text("Bind extra mouse buttons to any Lima action or record a keyboard shortcut, like Mac Mouse Fix. The shortcut is sent to the app that is focused when you press the mouse button.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                ForEach(3...8, id: \.self) { button in
                    accessoryMouseBindingRow(button: button)
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
                    .foregroundStyle(.secondary)
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

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Color scheme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Text("System follows macOS. Light and Dark apply only to Lima windows.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                AccentThemePicker(selection: $settings.accentTheme)
                Picker("Contrast", selection: $settings.contrastMode) {
                    ForEach(AppContrastMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.contrastMode.detail)
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
                InterfaceTextSizeControl()
                Picker("Interface density", selection: $settings.interfaceDensity) {
                    ForEach(AppInterfaceDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.interfaceDensity.detail)
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Launcher surfaces") {
                Picker("Return tools to Search after inactivity", selection: Binding(
                    get: { LauncherSurfaceTimeoutOption.allCases.first { $0.seconds == settings.launcherSurfaceTimeout } ?? .thirtySeconds },
                    set: { settings.launcherSurfaceTimeout = $0.seconds }
                )) {
                    ForEach(LauncherSurfaceTimeoutOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("Apply launcher timeout to Terminal", isOn: $settings.terminalUsesLauncherTimeout)
                Text("Typing, clicks, selection changes, edits, copies, and runs reset the timer. Active work suspends it.")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Music HUD") {
                Picker("Appearance", selection: $settings.musicHUDPresentation) {
                    Text("Mini").tag(MusicHUDPresentation.mini)
                    Text("Compact").tag(MusicHUDPresentation.compact)
                }
                .pickerStyle(.segmented)
                Toggle("Show artwork", isOn: $settings.musicShowArtwork)
                Toggle("Show playback controls", isOn: $settings.musicShowPlaybackControls)
                Toggle("Show progress", isOn: $settings.musicShowProgress)
                Toggle("Show when paused", isOn: $settings.musicShowWhenPaused)
                Toggle("Expand on click", isOn: $settings.musicExpandOnClick)
                Picker("Auto-collapse expanded player", selection: Binding(
                    get: { settings.musicExpandedTimeout },
                    set: { settings.musicExpandedTimeout = $0 }
                )) {
                    Text("5 seconds").tag(TimeInterval(5))
                    Text("10 seconds").tag(TimeInterval(10))
                    Text("15 seconds").tag(TimeInterval(15))
                }
                Picker("Dock position", selection: $settings.hudDockPosition) {
                    ForEach(HUDDockPosition.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Startup") {
                Toggle("Start Lima when I log in", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .limaFont(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Accessibility") {
                Label(
                    accessibilityTrusted ? "Accessibility access is working" : "Accessibility access is not available",
                    systemImage: accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
                .foregroundStyle(accessibilityTrusted ? .green : .orange)

                HStack {
                    Button(accessibilityTrusted ? "Recheck" : "Request Access") { requestAccessibilityAccess() }
                    Button("Open Settings") { openAccessibilitySettings() }
                    Spacer()
                    Text("Needed for selection, replace, paste, and windows")
                        .limaFont(.caption2)
                        .foregroundStyle(.tertiary)
                }

                DisclosureGroup("Troubleshooting") {
                    Text(Bundle.main.bundleURL.path)
                        .limaFont(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    private func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private var privacyTab: some View {
        Form {
            Section("Permission Center") {
                ForEach(PermissionCenter.PermissionID.allCases) { permission in
                    HStack {
                        Text(permission.title)
                        Spacer()
                        Text(permissionCenter.statuses[permission]?.rawValue ?? "Checking…").foregroundStyle(.secondary)
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
            Section("Persistence") {
                if let error = settings.lastError { Text(error).foregroundStyle(.orange) }
                Text("Notes, dictation, clipboard, settings, terminal sessions, workflows, and workspace state use private atomic storage with recovery copies.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                if #available(macOS 15.4, *) {
                    Text("macOS clipboard permission: \(pasteboardAccessDescription())")
                        .limaFont(.caption)
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                if secrets.references.isEmpty {
                    Text("No secrets saved.").foregroundStyle(.secondary)
                } else {
                    ForEach(secrets.references) { reference in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reference.name).limaFont(.callout.weight(.medium))
                                Text(reference.kind.title).limaFont(.caption).foregroundStyle(.secondary)
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
                    .limaFont(.caption2).foregroundStyle(.secondary)
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

    private var extensionsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Command profile", selection: Binding(
                    get: { commandManager.activeProfileID ?? commandManager.profiles.first?.id },
                    set: { id in if let id, let profile = commandManager.profiles.first(where: { $0.id == id }) { commandManager.activate(profile) } }
                )) {
                    ForEach(commandManager.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                .frame(width: 180)
                TextField("New profile", text: $commandProfileName)
                    .frame(width: 120)
                Button("Create") {
                    commandManager.createProfile(name: commandProfileName.isEmpty ? "New Profile" : commandProfileName)
                    commandProfileName = ""
                }
                if let profile = commandManager.activeProfile {
                    Button("Rename") {
                        let name = commandProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { commandManager.renameProfile(profile, name: name); commandProfileName = "" }
                    }
                    .disabled(commandProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Delete", role: .destructive) { commandManager.deleteProfile(profile) }
                }
            }
            HStack(spacing: 8) {
                Button("Open Folder") { NSWorkspace.shared.open(ApplicationPaths.extensions) }
                Button("Reload") { reloadExtensions() }
                Spacer()
                Text("\(viewModel.extensionCommands.count) commands")
                    .limaFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(ApplicationPaths.extensions.path)

            if !viewModel.extensionIssues.isEmpty {
                GroupBox("Extension issues") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.extensionIssues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.file).limaFont(.caption.weight(.semibold))
                                    Text(issue.message).limaFont(.caption).foregroundStyle(.secondary)
                                    if issue.extensionID != nil {
                                        Button("Approve requested capabilities") { viewModel.approveExtension(issue) }
                                            .buttonStyle(.borderless)
                                            .limaFont(.caption.weight(.medium))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 95)
                }
            }

            if viewModel.extensionCommands.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .limaFont(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No extension commands loaded").limaFont(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(extensionGroups) { group in
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .foregroundStyle(SettingsColors.readableViolet)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(group.name)
                                            .limaFont(.system(size: 13, weight: .semibold))
                                        Text("\(group.category) · \(group.provenance)")
                                            .limaFont(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let representative = group.commands.first {
                                        Toggle(
                                            "Pack",
                                            isOn: Binding(
                                                get: { settings.isPackEnabled(for: representative) },
                                                set: { settings.setPackEnabled($0, for: representative) }
                                            )
                                        )
                                            .toggleStyle(.checkbox)
                                            .limaFont(.caption2)
                                    }
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 36)

                                Divider().opacity(0.6)

                                ForEach(group.commands, id: \LoadedExtensionCommand.settingsIdentifier) { loaded in
                                    HStack(spacing: 6) {
                                        Toggle("", isOn: Binding(
                                            get: { commandManager.isEnabled(loaded.settingsIdentifier) },
                                            set: { commandManager.setEnabled($0, for: loaded.settingsIdentifier) }
                                        )).labelsHidden().toggleStyle(.checkbox)
                                        Button {
                                            commandManager.toggleFavorite(loaded.settingsIdentifier)
                                        } label: {
                                            Image(systemName: commandManager.isFavorite(loaded.settingsIdentifier) ? "star.fill" : "star")
                                                .foregroundStyle(commandManager.isFavorite(loaded.settingsIdentifier) ? .yellow : .secondary)
                                        }.buttonStyle(.borderless).help("Favorite command")
                                        ExtensionShortcutRow(settings: settings, loaded: loaded)
                                    }
                                    .disabled(group.commands.first.map { !settings.isPackEnabled(for: $0) } ?? false)
                                    .opacity(group.commands.first.map { settings.isPackEnabled(for: $0) ? 1 : 0.42 } ?? 1)
                                }
                            }
                            .liquidGlass(cornerRadius: 13, depth: .recessed, accentOpacity: 0.012)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
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

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .limaFont(.system(size: 56, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(settings.accentTheme.readablePrimary)
            Text("Lima").limaFont(.title.bold())
            Text("A fast, local-only macOS command launcher")
                .foregroundStyle(.secondary)
            Text("Local Python and Harper writing tools. No network requests or analytics.")
                .limaFont(.callout.weight(.medium))
            Text("Version \(updateService.currentVersion) · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                .limaFont(.caption)
                .foregroundStyle(.tertiary)
            Text(updateService.statusText)
                .limaFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if updateService.isInstalling {
                VStack(spacing: 7) {
                    ProgressView(value: updateService.installationProgress)
                        .tint(SettingsColors.readableIndigo)
                    Text("\(Int(updateService.installationProgress * 100))% · \(updateService.installationStage)")
                        .limaFont(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                Text("~/Library/Application Support/Lima/Updates/update.log")
                    .limaFont(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
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
                                    .stroke(LimaColors.primaryText.opacity(selection == theme ? 0.76 : 0.22), lineWidth: selection == theme ? LimaDesign.focusWidth : LimaDesign.borderWidth)
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
                    .foregroundStyle(.secondary)
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

private struct ShortcutRecorder: NSViewRepresentable {
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

private final class ShortcutCaptureView: NSView {
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

    init(settings: SettingsStore, viewModel: LauncherViewModel, updateService: UpdateService, reloadExtensions: @escaping () -> Void) {
        self.settingsStore = settings
        let view = SettingsView(settings: settings, viewModel: viewModel, updateService: updateService, reloadExtensions: reloadExtensions)
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
