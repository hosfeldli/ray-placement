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
    let commands: [LoadedExtensionCommand]
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, clipboard, writing, performance, usage, extensions, about

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .clipboard: return "clipboard.fill"
        case .writing: return "wand.and.stars"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .usage: return "chart.xyaxis.line"
        case .extensions: return "puzzlepiece.extension.fill"
        case .about: return "info.circle.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Launcher, shortcuts, and macOS access"
        case .clipboard: return "Private, on-device clipboard history"
        case .writing: return "Local AI correction behavior"
        case .performance: return "Control speed and system impact"
        case .usage: return "Live local work and private activity logs"
        case .extensions: return "Commands, integrations, and hotkeys"
        case .about: return "Version, updates, and project information"
        }
    }
}

private enum SettingsColors {
    static let indigo = Color(red: 0.33, green: 0.32, blue: 0.95)
    static let violet = Color(red: 0.64, green: 0.31, blue: 0.95)
    static let cyan = Color(red: 0.04, green: 0.67, blue: 0.82)
    static let heroGradient = LinearGradient(
        colors: [indigo, violet, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var updateService: UpdateService
    @ObservedObject private var usageMonitor = UsageMonitor.shared
    @ObservedObject private var modelDownloads = ModelDownloadService.shared
    @State private var confirmClipboardClear = false
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var selectedSection: SettingsSection = .general
    @State private var confirmUsageClear = false
    @State private var modelToRemove: LocalModelID?
    let reloadExtensions: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    Text(selectedSection.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 56)
                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
                selectedContent
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(width: 790, height: 560)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [SettingsColors.indigo.opacity(0.07), .clear, SettingsColors.cyan.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .animation(.easeOut(duration: 0.16), value: selectedSection)
        .alert("Clear usage log?", isPresented: $confirmUsageClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Log", role: .destructive) { usageMonitor.clear() }
        } message: {
            Text("This permanently removes RayPlacement's local task history. It never contains your selected text or document contents.")
        }
        .alert("Remove optional model?", isPresented: Binding(
            get: { modelToRemove != nil },
            set: { if !$0 { modelToRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { modelToRemove = nil }
            Button("Remove Model", role: .destructive) {
                if let modelToRemove { modelDownloads.remove(modelToRemove) }
                modelToRemove = nil
            }
        } message: {
            Text(modelToRemove.map { "This removes \(LocalModelCatalog.descriptor($0).title) from this Mac. You can download it again later." } ?? "")
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SettingsColors.heroGradient)
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("RayPlacement").font(.system(size: 14, weight: .bold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 14)

            ForEach(SettingsSection.allCases) { section in
                Button { selectedSection = section } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selectedSection == section ? Color.white : SettingsColors.indigo)
                            .frame(width: 23)
                        Text(section.title)
                            .font(.system(size: 13, weight: selectedSection == section ? .semibold : .medium))
                        Spacer()
                    }
                    .foregroundStyle(selectedSection == section ? Color.white : .primary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(selectedSection == section ? SettingsColors.heroGradient : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: selectedSection == section ? SettingsColors.indigo.opacity(0.18) : .clear, radius: 7, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .accessibilityValue(selectedSection == section ? "Selected" : "")
                .help(section.subtitle)
            }
            Spacer()
        }
        .frame(width: 184)
        .background(Color.black.opacity(0.025))
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .general: generalTab
        case .clipboard: clipboardTab
        case .writing: writingTab
        case .performance: performanceTab
        case .usage: usageTab
        case .extensions: extensionsTab
        case .about: aboutTab
        }
    }

    private var performanceTab: some View {
        Form {
            Section("Automatic allocation") {
                Toggle(isOn: $settings.dynamicPerformance) {
                    Label("Beta Dynamic Performance", systemImage: "gauge.with.dots.needle.67percent")
                }
                Label(settings.dynamicPerformanceDescription, systemImage: settings.dynamicPerformance ? "waveform.path.ecg" : "slider.horizontal.3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(settings.dynamicPerformance ? Color.accentColor : .secondary)
            }

            Section("Writing and note summaries") {
                performanceSlider(
                    "Writing",
                    selection: $settings.writingPerformance,
                    active: settings.runtimeWritingPerformance
                )
                LabeledContent(
                    "Active Qwen budget",
                    value: "\(settings.runtimeWritingPerformance.threadLimit) CPU thread\(settings.runtimeWritingPerformance.threadLimit == 1 ? "" : "s"), \(settings.runtimeWritingPerformance.timeoutDescription(settings.runtimeWritingPerformance.writingTimeout))"
                )
                if settings.runtimeWritingPerformance == .unbounded {
                    Label("Uses every CPU core with no timeout", systemImage: "bolt.trianglebadge.exclamationmark.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Section("Note dictation") {
                Picker("Transcription engine", selection: $settings.dictationEngine) {
                    ForEach(DictationEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Text(settings.dictationEngine.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Transcribe completed segments while recording", isOn: $settings.dictationTranscribeWhileRecording)
                    .disabled(settings.dictationEngine != .localWhisper)
                if settings.dictationTranscribeWhileRecording, settings.dictationEngine == .localWhisper {
                    Text("Whisper processes each secured one-minute segment in the background. This reduces work after Stop but uses the selected CPU budget during the meeting.")
                        .font(.caption)
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

            Section("AI-capable extensions") {
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
                    Text("Dynamic mode lowers each slider when Low Power Mode or heat requires it. Local models load only for a requested task and exit afterward. Extension limits are cooperative, so install only code you trust.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
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
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) performance")
    }

    private var writingTab: some View {
        Form {
            Section("Model assignment") {
                modelPicker("Grammar correction", selection: $settings.writingModel)
                modelPicker("Note summaries", selection: $settings.summaryModel)
                modelPicker("Formatter proposals", selection: $settings.formatterModel)
            }

            Section("Local model library") {
                ForEach(LocalModelCatalog.models) { model in
                    modelRow(model)
                }
                if modelDownloads.downloading != nil {
                    ProgressView(value: modelDownloads.progress)
                }
                Text(modelDownloads.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Your correction instructions") {
                Text("Tell Qwen which names, terms, capitalization, tone, or grammar style it must preserve. These instructions apply to every grammar check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.writingInstructions)
                    .font(.system(size: 12.5))
                    .frame(minHeight: 118)
                    .padding(7)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                    .accessibilityLabel("Grammar correction system instructions")
                HStack {
                    Text("\(settings.writingInstructions.count.formatted()) / 4,000 characters")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Restore Recommended Instructions") {
                        settings.resetWritingInstructions()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modelPicker(_ title: String, selection: Binding<LocalModelID>) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection) {
                ForEach(LocalModelCatalog.models) { model in
                    Text("\(model.title)\(LocalModelCatalog.isInstalled(model.id) ? "" : " · Not installed")")
                        .tag(model.id)
                        .disabled(!LocalModelCatalog.isInstalled(model.id))
                }
            }
            .labelsHidden()
            .frame(width: 245)
            .id(modelDownloads.installedGeneration)
        }
    }

    private func modelRow(_ model: LocalModelDescriptor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.bundled ? "shippingbox.fill" : "cpu.fill")
                .foregroundStyle(model.bundled ? SettingsColors.indigo : SettingsColors.cyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.callout.weight(.semibold))
                Text("\(model.detail) · \(model.sizeLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.bundled {
                Text("BUNDLED").font(.caption2.bold()).foregroundStyle(.green)
            } else if modelDownloads.downloading == model.id {
                Button("Cancel", action: modelDownloads.cancel)
            } else if LocalModelCatalog.isInstalled(model.id) {
                Button("Remove…") { modelToRemove = model.id }
            } else {
                Button("Install") { modelDownloads.install(model.id) }
                    .disabled(modelDownloads.downloading != nil)
            }
        }
    }

    private var usageTab: some View {
        let summary = usageMonitor.summary
        return Form {
            Section("Live activity") {
                if usageMonitor.activeTasks.isEmpty {
                    Label("No local AI or extension process is running", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(usageMonitor.activeTasks) { task in
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.operation).font(.callout.weight(.semibold))
                                Text("\(task.model ?? task.category.rawValue) · \(task.performance.title) · \(task.threads) threads")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(task.startedAt, style: .timer).font(.caption.monospacedDigit())
                        }
                    }
                }
            }

            Section("Today") {
                LabeledContent("Completed tasks", value: summary.completedToday.formatted())
                LabeledContent("Failed or cancelled", value: summary.failedToday.formatted())
                LabeledContent("Local model time", value: durationLabel(summary.modelSecondsToday))
                LabeledContent("Characters processed", value: summary.inputCharactersToday.formatted())
                LabeledContent("Characters produced", value: summary.outputCharactersToday.formatted())
            }

            Section("Recent work") {
                if usageMonitor.events.isEmpty {
                    Text("Completed AI and executable-extension tasks will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usageMonitor.events.prefix(20)) { event in
                        HStack(spacing: 10) {
                            Image(systemName: event.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(event.succeeded ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.operation).font(.callout.weight(.medium))
                                Text("\(event.model ?? event.category.rawValue) · \(event.performance) · \(event.threads) threads · \(durationLabel(event.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(event.startedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    Button("Reveal Log", action: usageMonitor.revealLog)
                        .disabled(usageMonitor.events.isEmpty)
                    Button("Clear Log…", role: .destructive) { confirmUsageClear = true }
                        .disabled(usageMonitor.events.isEmpty)
                }
                Label("The log stays on this Mac and records task names, model, limits, duration, counts, and success—not selected text, note contents, prompts, or document data.", systemImage: "hand.raised.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int(seconds) / 60
        let remaining = Int(seconds) % 60
        return "\(minutes)m \(remaining)s"
    }

    private var generalTab: some View {
        Form {
            Section("Launcher") {
                LabeledContent("Activation shortcut") {
                    ShortcutRecorder(shortcut: $settings.activationShortcut)
                        .frame(width: 145, height: 28)
                }
                LabeledContent("Open Notes") {
                    ShortcutRecorder(shortcut: $settings.notesShortcut, label: "Open Notes shortcut")
                        .frame(width: 145, height: 28)
                }
                LabeledContent("Quick Note sidebar") {
                    ShortcutRecorder(shortcut: $settings.quickNoteShortcut, label: "Quick Note sidebar shortcut")
                        .frame(width: 145, height: 28)
                }
                LabeledContent("Start or stop note dictation") {
                    ShortcutRecorder(shortcut: $settings.dictationShortcut, label: "Note dictation shortcut")
                        .frame(width: 145, height: 28)
                }
                Toggle("Start RayPlacement when I log in", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Accessibility") {
                Label(
                    accessibilityTrusted ? "Accessibility access is working" : "Accessibility access is not available",
                    systemImage: accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )
                .foregroundStyle(accessibilityTrusted ? .green : .orange)

                Text("Writing checks, replacing selected text, window commands, and automatic paste use this permission. The launcher and its global shortcuts do not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Request Access") { requestAccessibilityAccess() }
                    Button("Open Accessibility Settings") { openAccessibilitySettings() }
                    Button("Reveal This App") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }

                DisclosureGroup("App identity") {
                    Text(Bundle.main.bundleURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            Section {
                DisclosureGroup("Keyboard reference") {
                    LabeledContent("Navigate", value: "↑ / ↓")
                    LabeledContent("Run", value: "Return")
                    LabeledContent("Back", value: "Escape")
                    LabeledContent("Visible result", value: "⌘1 … ⌘9")
                }
            }
        }
        .formStyle(.grouped)
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

    private var clipboardTab: some View {
        Form {
            Section("Local clipboard history") {
                Toggle("Remember copied text", isOn: $settings.clipboardEnabled)
                Stepper("Keep up to \(settings.clipboardLimit) items", value: $settings.clipboardLimit, in: 10...500, step: 10)
                Text("Off by default. When enabled, RayPlacement checks the macOS clipboard and stores text only in ~/Library/Application Support/RayPlacement. Nothing is sent over the network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if #available(macOS 15.4, *) {
                    Text("macOS clipboard permission: \(pasteboardAccessDescription())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Clear Clipboard History", role: .destructive) {
                    confirmClipboardClear = true
                }
            }
        }
        .formStyle(.grouped)
        .alert("Clear Clipboard History?", isPresented: $confirmClipboardClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { viewModel.clipboard.clear() }
        } message: {
            Text("This permanently removes every item RayPlacement has saved from the clipboard.")
        }
    }

    private var extensionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ApplicationPaths.extensions.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Button("Open Extensions Folder") { NSWorkspace.shared.open(ApplicationPaths.extensions) }
                        Button("Reload") { reloadExtensions() }
                        Spacer()
                        Text("\(viewModel.extensionCommands.count) commands")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            } label: {
                Label("Add functionality", systemImage: "folder.badge.plus")
            }

            if !viewModel.extensionIssues.isEmpty {
                GroupBox("Extension issues") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.extensionIssues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.file).font(.caption.weight(.semibold))
                                    Text(issue.message).font(.caption).foregroundStyle(.secondary)
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
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No extension commands loaded").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(extensionGroups) { group in
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .foregroundStyle(SettingsColors.violet)
                                    Text(group.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Toggle(
                                        "Enabled",
                                        isOn: Binding(
                                            get: { settings.isExtensionEnabled(group.id) },
                                            set: { settings.setExtensionEnabled($0, extensionID: group.id) }
                                        )
                                    )
                                    .toggleStyle(.checkbox)
                                    .font(.caption)
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 36)

                                Divider().opacity(0.6)

                                ForEach(group.commands, id: \LoadedExtensionCommand.settingsIdentifier) { loaded in
                                    ExtensionShortcutRow(settings: settings, loaded: loaded)
                                        .disabled(!settings.isExtensionEnabled(group.id))
                                        .opacity(settings.isExtensionEnabled(group.id) ? 1 : 0.48)
                                }
                            }
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
    }

    private var extensionGroups: [SettingsExtensionGroup] {
        Dictionary(grouping: viewModel.extensionCommands, by: \LoadedExtensionCommand.extensionID)
            .map { id, commands in
                SettingsExtensionGroup(
                    id: id,
                    name: commands.first?.extensionName ?? id,
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
                .font(.system(size: 56, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text("RayPlacement").font(.title.bold())
            Text("A fast, local-only macOS command launcher")
                .foregroundStyle(.secondary)
            Text("Local-only writing tools. No cloud AI. No analytics.")
                .font(.callout.weight(.medium))
            Text("Version \(updateService.currentVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(updateService.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if updateService.isInstalling {
                VStack(spacing: 7) {
                    ProgressView(value: updateService.installationProgress)
                        .tint(SettingsColors.indigo)
                    Text("\(Int(updateService.installationProgress * 100))% · \(updateService.installationStage)")
                        .font(.caption2.weight(.medium))
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
                Text("Updates are downloaded from GitHub, verified, rebuilt locally with this Mac’s signing identity, and installed after confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("~/Library/Application Support/RayPlacement/Updates/update.log")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
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

private struct ExtensionShortcutRow: View {
    @ObservedObject var settings: SettingsStore
    let loaded: LoadedExtensionCommand

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: loaded.command.icon ?? "puzzlepiece.extension.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(loaded.command.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 10)
            Toggle(
                "Function",
                isOn: Binding(
                    get: { settings.isCommandEnabled(loaded) },
                    set: { settings.setCommandEnabled($0, for: loaded) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption2)
            Toggle(
                "Hotkey",
                isOn: Binding(
                    get: { settings.isHotkeyEnabled(loaded) },
                    set: { settings.setHotkeyEnabled($0, for: loaded) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption2)
            .disabled(!settings.isCommandEnabled(loaded))
            ShortcutRecorder(
                shortcut: Binding(
                    get: { settings.effectiveShortcut(for: loaded) ?? "" },
                    set: { settings.setShortcut($0, for: loaded) }
                ),
                label: "\(loaded.command.title) shortcut"
            )
            .frame(width: 112, height: 28)
            .disabled(!settings.isCommandEnabled(loaded) || !settings.isHotkeyEnabled(loaded))

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
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
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
            contentRect: NSRect(x: 0, y: 0, width: 790, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RayPlacement Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        settingsStore.refreshLaunchAtLogin()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
