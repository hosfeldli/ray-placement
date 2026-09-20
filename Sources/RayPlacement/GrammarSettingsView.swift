import SwiftUI
import RayPlacementWriting

@MainActor
struct GrammarSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let openDebugger: () -> Void
    @State private var tab: GrammarTab = .overview
    @State private var testInput = "This are a grammer sentence."
    @State private var apiKey = ""
    @State private var isTestingConnection = false
    @State private var connectionMessage: String?
    @State private var isRunningTest = false
    @State private var testResult: GrammarEnsembleCoordinator.Result?
    @State private var testOutput: String?
    @State private var testLatencyMS: Int?
    @State private var testError: String?

    private enum GrammarTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case ensemble = "Ensemble"
        case provider = "Provider"
        case debugger = "Debugger"
        case analytics = "Analytics"
        var id: String { rawValue }
    }

    private var runs: [GrammarDebugRun] { GrammarDebugStore.shared.recentRuns(limit: 20) }
    private var analytics: [GrammarSeedAnalytics] { GrammarDebugStore.shared.analytics() }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Grammar area", selection: $tab) {
                ForEach(GrammarTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Group {
                switch tab {
                case .overview: overview
                case .ensemble: ensemble
                case .provider: provider
                case .debugger: debugger
                case .analytics: analyticsView
                }
            }
        }
    }

    private var overview: some View {
        Form {
            Section("Grammar engine") {
                HStack {
                    Label(settings.grammarEngineMode == .externalAPI ? "External API" : "Local", systemImage: settings.grammarEngineMode == .externalAPI ? "cloud.fill" : "lock.shield.fill")
                    Spacer()
                    statusBadge
                }
                if settings.grammarEngineMode == .externalAPI {
                    Text("\(settings.developerGrammarProvider.title) · \(settings.developerGrammarModel)")
                        .foregroundStyle(LimaTheme.textSecondary)
                } else {
                    Text("Local checker · no network request")
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Picker("Correction style", selection: $settings.grammarCorrectionMode) {
                    ForEach(GrammarCorrectionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.grammarCorrectionMode.detail)
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                LabeledContent("Ensemble", value: "\(settings.grammarEnsembleStrategy.title) · \(settings.grammarEnsembleStrategy.candidateCount) candidates")
                LabeledContent("Adjudication", value: settings.grammarJudgeOnDisagreement ? "Judge on disagreement" : "Disabled")
            }

            Section("Recent health") {
                if let run = runs.first {
                    LabeledContent("Last check", value: run.status.capitalized)
                    LabeledContent("Candidates", value: "\(run.candidateCount)")
                    LabeledContent("Corrections applied", value: "\(run.appliedCount)")
                    LabeledContent("Judge", value: run.judgeUsed ? "Used" : "Not required")
                } else {
                    Text("No grammar checks have been recorded yet.")
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                LabeledContent("Stored runs", value: "\(GrammarDebugStore.shared.recentRuns(limit: 500).count)")
            }

            Section("Grammar Test Lab") {
                TextEditor(text: $testInput)
                    .frame(minHeight: 70)
                    .limaEditorSurface(cornerRadius: 6)
                Text("Run the configured engine and inspect the complete trace in Grammar Debugger.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                HStack {
                    Button {
                        runTestLab()
                    } label: {
                        if isRunningTest { ProgressView().controlSize(.small) } else { Text("Run Ensemble") }
                    }
                    .disabled(isRunningTest || settings.grammarEngineMode == .externalAPI && settings.developerGrammarConfigurationForTesting == nil)
                    Button("Open Grammar Debugger", action: openDebugger)
                }
                if let result = testResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FINAL").font(.caption.weight(.bold)).foregroundStyle(LimaTheme.textSecondary)
                        Text(result.report.text).textSelection(.enabled)
                        Text("\(result.successfulCandidateCount) candidates · \(result.judgeUsed ? "Judge used" : "Judge not required") · \(result.report.appliedCount) applied")
                            .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                        Button("Open Run in Debugger") { openDebugger() }
                    }
                    .padding(8)
                    .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let testOutput {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FINAL").font(.caption.weight(.bold)).foregroundStyle(LimaTheme.textSecondary)
                        Text(testOutput).textSelection(.enabled)
                        Text("Local engine · no network request\(testLatencyMS.map { " · \($0) ms" } ?? "")")
                            .font(.caption).foregroundStyle(LimaTheme.textSecondary)
                    }
                    .padding(8)
                    .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let testError { Text(testError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var statusBadge: some View {
        Label(settings.grammarEngineMode == .local || settings.enhancedGrammarAPIKeyStored ? "Ready" : "Needs key", systemImage: settings.grammarEngineMode == .local || settings.enhancedGrammarAPIKeyStored ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(settings.grammarEngineMode == .local || settings.enhancedGrammarAPIKeyStored ? .green : .orange)
            .font(.caption.weight(.semibold))
    }

    private var ensemble: some View {
        Form {
            Section("Strategy") {
                Picker("Ensemble", selection: $settings.grammarEnsembleStrategy) {
                    ForEach(GrammarEnsembleStrategy.allCases) { strategy in
                        Text("\(strategy.title) · \(strategy.candidateCount) candidates").tag(strategy)
                    }
                }
                .pickerStyle(.segmented)
                Text(strategyDescription)
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }

            Section("Candidate profiles") {
                ForEach(GrammarCandidateProfile.profiles(for: settings.grammarEnsembleStrategy)) { profile in
                    DisclosureGroup {
                        LabeledContent("Diversity seed", value: "\(profile.diversitySeed)")
                        LabeledContent("Temperature", value: profile.temperature.map { String(format: "%.2f", $0) } ?? "Provider default")
                        LabeledContent("Prompt version", value: profile.promptVersion)
                        Text(profile.instructions)
                            .font(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                        Button("View Full Instructions") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(profile.instructions, forType: .string) }
                    } label: {
                        HStack {
                            Text(profile.id.replacingOccurrences(of: "-", with: " ").capitalized)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text("seed \(profile.diversitySeed)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(LimaTheme.textSecondary)
                        }
                    }
                }
            }

            Section("Adjudication") {
                Toggle("Use judge when candidates materially disagree", isOn: $settings.grammarJudgeOnDisagreement)
                Text("The judge evaluates existing proposals only. It may select a candidate or reject the disputed correction; it cannot invent replacement text.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var strategyDescription: String {
        switch settings.grammarEnsembleStrategy {
        case .fast: return "Lowest API cost and latency."
        case .balanced: return "Recommended accuracy and cost balance."
        case .thorough: return "Maximum candidate diversity."
        }
    }

    private var provider: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: Binding(get: { settings.developerGrammarProvider }, set: { settings.selectDeveloperGrammarProvider($0) })) {
                    ForEach(DeveloperGrammarProvider.allCases) { Text($0.title).tag($0) }
                }
                Picker("Model", selection: $settings.developerGrammarModel) {
                    ForEach(settings.developerGrammarProvider.modelOptions) { Text($0.title).tag($0.id) }
                    if !settings.developerGrammarProvider.modelOptions.contains(where: { $0.id == settings.developerGrammarModel }) {
                        Text("Custom: \(settings.developerGrammarModel)").tag(settings.developerGrammarModel)
                    }
                }
                TextField("Custom model ID", text: $settings.developerGrammarModel)
                    .textFieldStyle(.roundedBorder)
                Picker("Engine", selection: $settings.grammarEngineMode) {
                    Text("Local").tag(GrammarEngineMode.local)
                    Text("External API").tag(GrammarEngineMode.externalAPI)
                }
                .pickerStyle(.segmented)
            }
            Section("API key") {
                SecureField(settings.enhancedGrammarAPIKeyStored ? "Enter a replacement API key" : "API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save API Key") {
                        do {
                            try settings.saveDeveloperGrammarAPIKey(apiKey)
                            apiKey = ""
                            connectionMessage = "Saved securely in macOS Keychain."
                        } catch { connectionMessage = error.localizedDescription }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear Stored Key", role: .destructive) {
                        do {
                            try settings.saveDeveloperGrammarAPIKey("")
                            connectionMessage = "Removed from macOS Keychain."
                        } catch { connectionMessage = error.localizedDescription }
                    }
                    if settings.enhancedGrammarAPIKeyStored { Label("Stored", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let connectionMessage { Text(connectionMessage).font(.caption).foregroundStyle(LimaTheme.textSecondary) }
                HStack {
                    Button {
                        testConnection()
                    } label: {
                        if isTestingConnection { ProgressView().controlSize(.small) } else { Text("Test Connection") }
                    }
                    .disabled(isTestingConnection || !settings.enhancedGrammarAPIKeyStored)
                    if let connectionMessage { Text(connectionMessage).font(.caption).foregroundStyle(LimaTheme.textSecondary) }
                }
            }
            Section("Advanced provider settings") {
                TextField("Base URL", text: $settings.developerGrammarBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Custom compatible endpoints can be configured here. External failures are reported directly; Lima never falls back to Local automatically.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var debugger: some View {
        Form {
            Section("Grammar Debugger") {
                HStack {
                    Label("Recording", systemImage: "record.circle")
                        .foregroundStyle(.green)
                    Spacer()
                    Text("\(runs.count) recent runs")
                        .foregroundStyle(LimaTheme.textSecondary)
                }
                Toggle("Record source text", isOn: $settings.grammarDebugStoreSourceText)
                Stepper("Retention: \(settings.grammarDebugRetentionDays) days", value: $settings.grammarDebugRetentionDays, in: 1...3650)
                Stepper("Maximum runs: \(settings.grammarDebugMaximumRuns)", value: $settings.grammarDebugMaximumRuns, in: 10...100_000, step: 10)
                Text("Prompts, provider responses, scoring components, and rejected edits remain local. API keys and authorization headers are never stored.")
                    .font(.caption)
                    .foregroundStyle(LimaTheme.textSecondary)
                Button("Open Grammar Debugger", action: openDebugger)
                Button("Export Analytics…") {
                    do { let url = try GrammarDebugStore.shared.export(includeSource: settings.grammarDebugStoreSourceText); NSWorkspace.shared.activateFileViewerSelecting([url]) } catch { settings.lastError = error.localizedDescription }
                }
            }
            Section("Recent runs") {
                ForEach(runs) { run in
                    HStack {
                        Image(systemName: run.status == "completed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(run.status == "completed" ? .green : .orange)
                        Text(run.startedAt, style: .relative)
                        Spacer()
                        Text("\(run.strategy.title) · \(run.candidateCount) candidates")
                            .font(.caption)
                            .foregroundStyle(LimaTheme.textSecondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private var analyticsView: some View {
        Form {
            Section("Recent checks") {
                LabeledContent("Checks", value: "\(runs.count)")
                let successful = runs.filter { $0.status == "completed" }.count
                LabeledContent("Success rate", value: runs.isEmpty ? "—" : "\(Int(Double(successful) / Double(runs.count) * 100))%")
                LabeledContent("Judge invocation", value: runs.isEmpty ? "—" : "\(Int(Double(runs.filter { $0.judgeUsed }.count) / Double(runs.count) * 100))%")
            }
            Section("Candidate analytics") {
                if analytics.isEmpty {
                    Text("Candidate analytics will appear after the first external ensemble run.").foregroundStyle(LimaTheme.textSecondary)
                } else {
                    ForEach(analytics) { item in
                        HStack {
                            Text(item.profileID)
                            Spacer()
                            Text("\(Int(item.contributionRate * 100))% contribution")
                            Text("\(item.averageLatencyMS) ms")
                                .foregroundStyle(LimaTheme.textSecondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.small)
    }

    private func testConnection() {
        guard let configuration = settings.developerGrammarConfigurationForTesting else {
            connectionMessage = "Save a key, model, and base URL first."
            return
        }
        isTestingConnection = true
        connectionMessage = nil
        let started = Date()
        StealthGrammarRemoteClient().testConnection(configuration: configuration) { result in
            isTestingConnection = false
            let latency = Int(Date().timeIntervalSince(started) * 1_000)
            switch result {
            case .success: connectionMessage = "Connected · \(latency) ms"
            case .failure(let error): connectionMessage = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func runTestLab() {
        testError = nil
        testResult = nil
        testOutput = nil
        testLatencyMS = nil
        let started = Date()

        if settings.grammarEngineMode == .local {
            isRunningTest = true
            RuleBasedWritingChecker().checkLocal(testInput) { result in
                testLatencyMS = Int(Date().timeIntervalSince(started) * 1_000)
                switch result {
                case .success(let review): testOutput = review.suggestedText
                case .failure(let error): testError = error.localizedDescription
                }
                isRunningTest = false
            }
            return
        }

        guard let configuration = settings.developerGrammarConfigurationForTesting else {
            testError = "Save a provider key, model, and base URL first."
            return
        }
        isRunningTest = true
        let protected = StealthGrammarService.protect(testInput, ignoreList: settings.writingInstructions)
        Task { @MainActor in
            do {
                let result = try await GrammarEnsembleCoordinator(remoteClient: StealthGrammarRemoteClient()).run(
                    contextText: protected.contextText,
                    source: testInput,
                    protected: protected,
                    configuration: configuration,
                    strategy: settings.grammarEnsembleStrategy,
                    systemPrompt: StealthGrammarRemoteClient.systemPrompt,
                    useJudgeOnDisagreement: settings.grammarJudgeOnDisagreement
                )
                testLatencyMS = Int(Date().timeIntervalSince(started) * 1_000)
                testResult = result
            } catch { testError = error.localizedDescription }
            isRunningTest = false
        }
    }
}
