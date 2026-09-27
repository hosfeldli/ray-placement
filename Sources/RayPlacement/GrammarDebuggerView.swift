import SwiftUI
import AppKit
import RayPlacementWriting
import Combine

@MainActor
struct GrammarDebuggerView: View {
    @ObservedObject var settings: SettingsStore
    @State private var runs: [GrammarDebugRun] = []
    @State private var analytics: [GrammarSeedAnalytics] = []
    @State private var selectedRunID: UUID?
    @State private var candidates: [GrammarDebugCandidate] = []
    @State private var feedback: [GrammarDebugFeedback] = []
    @State private var requests: [GrammarDebugRequest] = []
    @State private var rejectionAggregates: [GrammarRejectionAggregate] = []
    @State private var detailTab: RunDetailTab = .overview
    @State private var showRerunOptions = false
    @State private var rerunJudge = true
    @State private var rerunStrategy: GrammarEnsembleStrategy = .balanced
    @State private var status: String?
    @State private var benchmarkSummary: GrammarBenchmarkSummary?
    @State private var isBenchmarking = false
    @State private var benchmarkComparison: GrammarBenchmarkComparison?

    private enum RunDetailTab: String, CaseIterable, Identifiable { case overview = "Overview", input = "Input", candidates = "Candidates", consensus = "Consensus", judge = "Judge", output = "Output", network = "Network"; var id: String { rawValue } }

    var body: some View {
        HSplitView {
            List(selection: $selectedRunID) {
                Section("Recent runs") {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.startedAt, style: .relative)
                            Text("\(run.strategy.title) · \(run.status) · \(run.appliedCount) applied")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(run.id)
                    }
                }
            }
            .frame(minWidth: 230, idealWidth: 270)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let run = runs.first(where: { $0.id == selectedRunID }) {
                        runDetail(run)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Select a grammar run").font(.headline)
                            Text("Candidate traces are retained locally in Lima’s SQLite debugger database.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    }
                    analyticsSection
                    benchmarkSection
                }
                .padding(20)
            }
            .frame(minWidth: 620)
        }
        .frame(minWidth: 930, minHeight: 650)
        .safeAreaInset(edge: .top) {
            HStack {
                Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button("Purge Retained Runs", role: .destructive) { purge() }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear { reload() }
        .onReceive(Just(selectedRunID)) { id in select(id) }
    }

    @ViewBuilder private func runDetail(_ run: GrammarDebugRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Run Details").font(.title2.bold())
                Spacer()
                Button("Run Again") { rerun(run, strategy: run.strategy, judge: run.judgeUsed) }
                Button("Run Again With…") { rerunStrategy = run.strategy; rerunJudge = run.judgeUsed; showRerunOptions = true }
                Label(run.judgeUsed ? "Judge used" : "Judge not used", systemImage: run.judgeUsed ? "checkmark.seal" : "minus.circle").foregroundStyle(run.judgeUsed ? .green : .secondary)
            }
            Text("\(run.strategy.title) · \(run.candidateCount) candidates · \(run.appliedCount) final edits · \(run.totalLatencyMS) ms · \(run.apiCallCount) API calls")
                .foregroundStyle(.secondary)
            if let model = run.model { Text("\(run.provider ?? "Provider") · \(model) · \(run.inputTokens) in / \(run.outputTokens) out tokens").font(.caption).foregroundStyle(.secondary) }
            if let error = run.error { Text(error).foregroundStyle(.red) }
            if let judgeError = run.judgeError { Text("Judge: \(judgeError)").font(.caption).foregroundStyle(.orange) }
            Picker("Run detail", selection: $detailTab) { ForEach(RunDetailTab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            switch detailTab {
            case .overview:
                HStack { metric("Status", run.status); metric("Candidates", "\(run.candidateCount)"); metric("Applied", "\(run.appliedCount)"); metric("Safety rejects", "\(run.safetyRejectedCount)") }
                if !run.rejectionReasons.isEmpty { rejectionView(run.rejectionReasons) }
                if let snapshot = run.configurationSnapshot { snapshotView(snapshot) }
            case .input:
                inputView(run)
            case .candidates:
                candidateComparison(run: run)
                ForEach(candidates) { candidate in candidateCard(candidate, runID: run.id) }
            case .consensus:
                changeList(title: "Final consensus", changes: run.finalChanges)
                if candidates.isEmpty { Text("No candidate records.").foregroundStyle(.secondary) }
                else { Text("Candidate agreement is computed from accepted edit overlap.").font(.caption).foregroundStyle(.secondary) }
            case .judge:
                VStack(alignment: .leading) { Text(run.judgeUsed ? "Judge was invoked for disputed proposals." : "Judge was not invoked."); if let error = run.judgeError { Text(error).foregroundStyle(.orange) } }.font(.caption)
            case .output:
                changeList(title: "Applied output edits", changes: run.finalChanges)
                Text("\(run.appliedCount) edits applied").font(.caption).foregroundStyle(.secondary)
            case .network:
                networkView(run)
            }
            HStack {
                Button { saveFeedback(runID: run.id, candidateID: nil, decision: "approved") } label: { Label("Approve run", systemImage: "checkmark.circle") }
                Button { saveFeedback(runID: run.id, candidateID: nil, decision: "rejected") } label: { Label("Reject run", systemImage: "xmark.circle") }
            }
        }
        .confirmationDialog("Run Again With", isPresented: $showRerunOptions) {
            Button("Current Settings · \(rerunStrategy.title)") { if let run = runs.first(where: { $0.id == selectedRunID }) { rerun(run, strategy: rerunStrategy, judge: rerunJudge) } }
            Button("Fast") { rerunStrategy = .fast; if let run = runs.first(where: { $0.id == selectedRunID }) { rerun(run, strategy: .fast, judge: rerunJudge) } }
            Button("Balanced") { rerunStrategy = .balanced; if let run = runs.first(where: { $0.id == selectedRunID }) { rerun(run, strategy: .balanced, judge: rerunJudge) } }
            Button("Thorough") { rerunStrategy = .thorough; if let run = runs.first(where: { $0.id == selectedRunID }) { rerun(run, strategy: .thorough, judge: rerunJudge) } }
            Button(rerunJudge ? "Disable Judge" : "Enable Judge") { rerunJudge.toggle() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(value).font(.headline); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
    @ViewBuilder private func rejectionView(_ values: [String: Int]) -> some View { VStack(alignment: .leading) { Text("Rejection reasons").font(.caption.bold()); ForEach(values.sorted { $0.value > $1.value }, id: \.key) { Text("\($0.key): \($0.value)").font(.caption.monospaced()) } } }
    @ViewBuilder private func inputView(_ run: GrammarDebugRun) -> some View { if let source = run.sourceText { HStack(alignment: .top) { Text(source).font(.system(.caption, design: .monospaced)).textSelection(.enabled); if let context = run.contextText { Divider(); Text(context).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }.frame(maxWidth: .infinity, alignment: .leading) } else { Text("Source capture is disabled for this run.").foregroundStyle(.secondary) } }
    @ViewBuilder private func snapshotView(_ snapshot: GrammarRunConfigurationSnapshot) -> some View { DisclosureGroup("Configuration snapshot") { Text("Provider: \(snapshot.provider) · model: \(snapshot.model) · judge: \(snapshot.judgeEnabled ? "on" : "off")").font(.caption); Text("Candidates: \(snapshot.candidates.filter(\.enabled).map(\.id).joined(separator: ", "))").font(.caption) }.font(.caption) }
    @ViewBuilder private func networkView(_ run: GrammarDebugRun) -> some View { VStack(alignment: .leading) { Text("\(run.apiCallCount) recorded API calls · \(run.inputTokens) input / \(run.outputTokens) output tokens"); ForEach(requests) { request in Text("\(request.kind) · \(request.status) · \(request.latencyMS) ms · \(request.id)").font(.caption.monospaced()) } }.font(.caption) }
    @ViewBuilder private func candidateComparison(run: GrammarDebugRun) -> some View { if candidates.count > 1 { VStack(alignment: .leading) { Text("Candidate comparison").font(.headline); HStack { Text("Candidate").bold(); Spacer(); Text("Accepted"); Text("Rejected"); Text("Latency") }; ForEach(candidates) { c in HStack { Text(c.profileID); Spacer(); Text("\(c.acceptedChanges.count)"); Text("\(c.rejectedCount)"); Text("\(c.latencyMS) ms") }.font(.caption); candidateDiff(c) } } } }
    @ViewBuilder private func candidateDiff(_ candidate: GrammarDebugCandidate) -> some View { ForEach(Array(candidate.acceptedChanges.enumerated()), id: \.offset) { _, change in HStack(alignment: .top) { Text("− \(change.find)").foregroundStyle(.red); Text("+ \(change.replacement)").foregroundStyle(.green) }.font(.system(.caption, design: .monospaced)) } }

    @ViewBuilder private func candidateCard(_ candidate: GrammarDebugCandidate, runID: UUID) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(candidate.instructions).font(.caption).foregroundStyle(.secondary)
                Text(candidate.prompt).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                changeList(title: "Accepted edits", changes: candidate.acceptedChanges)
                changeList(title: "Raw proposals", changes: candidate.rawChanges)
                if let error = candidate.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button { saveFeedback(runID: runID, candidateID: candidate.id, decision: "approved") } label: { Label("Approve", systemImage: "hand.thumbsup") }
                    Button { saveFeedback(runID: runID, candidateID: candidate.id, decision: "rejected") } label: { Label("Reject", systemImage: "hand.thumbsdown") }
                    Button("Clear") { GrammarDebugStore.shared.clearFeedback(runID: runID, candidateID: candidate.id); select(runID) }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                Text(candidate.profileID).font(.headline)
                Text("seed \(candidate.seed)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text("\(candidate.latencyMS) ms · \(candidate.acceptedChanges.count) accepted · \(candidate.rejectedCount) rejected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func changeList(title: String, changes: [StealthGrammarDocumentChange]) -> some View {
        if !changes.isEmpty {
            VStack(alignment: .leading) {
                Text(title).font(.caption.bold())
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    Text("\(change.find.debugDescription) → \(change.replacement.debugDescription)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }

    private var analyticsSection: some View {
        GroupBox("Per-seed analytics") {
            if analytics.isEmpty { Text("No candidate analytics yet.").foregroundStyle(.secondary) }
            else { ForEach(analytics) { seed in
                HStack {
                    Text("\(seed.profileID) · \(seed.seed)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(seed.runCount) runs")
                    Text("\(Int(seed.contributionRate * 100))% contribution")
                    Text("\(Int(seed.rejectionRate * 100))% rejected")
                    Text("\(seed.averageLatencyMS) ms")
                }.font(.caption)
            }}
        }
    }

    private var benchmarkSection: some View {
        GroupBox("Benchmark corpus") {
            HStack {
                Button { runBenchmark() } label: { isBenchmarking ? AnyView(ProgressView()) : AnyView(Label("Run External Grammar Benchmark", systemImage: "speedometer")) }.disabled(isBenchmarking)
                if let summary = benchmarkSummary { Text("\(summary.passed)/\(summary.results.count) passed · \(Int(summary.accuracy * 100))% accuracy · \(summary.totalLatencyMS) ms · \(summary.apiCalls) calls") }
                if let comparison = benchmarkComparison { ForEach(comparison.rows) { row in Text("\(row.strategy.title): \(Int(row.accuracy * 100))% · \(row.latencyMS) ms · \(row.apiCalls) calls").font(.caption) } }
                if let status { Text(status).foregroundStyle(.secondary) }
            }
            Text("Uses the configured provider and ensemble strategy; benchmark text is never stored unless source capture is enabled.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reload() { runs = GrammarDebugStore.shared.recentRuns(); analytics = GrammarDebugStore.shared.analytics(); rejectionAggregates = GrammarDebugStore.shared.rejectionAggregates(); if selectedRunID == nil { selectedRunID = runs.first?.id }; if let id = selectedRunID { select(id) } }
    private func select(_ id: UUID?) { guard let id else { candidates = []; feedback = []; requests = []; return }; candidates = GrammarDebugStore.shared.candidates(for: id); feedback = GrammarDebugStore.shared.feedback(for: id); requests = GrammarDebugStore.shared.requests(for: id) }
    private func saveFeedback(runID: UUID, candidateID: String? = nil, decision: String) { GrammarDebugStore.shared.saveFeedback(GrammarDebugFeedback(runID: runID, candidateID: candidateID, decision: decision, note: nil, createdAt: Date())); select(runID); analytics = GrammarDebugStore.shared.analytics() }
    private func export() { do { let url = try GrammarDebugStore.shared.export(includeSource: settings.grammarDebugStoreSourceText); NSWorkspace.shared.activateFileViewerSelecting([url]); status = "Exported debugger trace." } catch { status = error.localizedDescription } }
    private func purge() { GrammarDebugStore.shared.prune(maxRuns: settings.grammarDebugMaximumRuns, retentionDays: settings.grammarDebugRetentionDays); reload(); status = "Retention policy applied." }
    private func rerun(_ run: GrammarDebugRun, strategy: GrammarEnsembleStrategy, judge: Bool) {
        guard let source = run.sourceText else { status = "Enable source capture to rerun this run."; return }
        guard let configuration = settings.developerGrammarConfigurationForTesting else { status = "Save a provider key, model, and base URL first."; return }
        let protected = StealthGrammarService.protect(source, ignoreList: settings.writingInstructions)
        status = "Running again…"
        Task { @MainActor in
            do { _ = try await GrammarEnsembleCoordinator(remoteClient: StealthGrammarRemoteClient()).run(contextText: protected.contextText, source: source, protected: protected, configuration: configuration, strategy: strategy, systemPrompt: StealthGrammarRemoteClient.systemPrompt, useJudgeOnDisagreement: judge); reload(); status = "Rerun completed." }
            catch { status = error.localizedDescription }
        }
    }

    private func runBenchmark() {
        guard let configuration = settings.developerGrammarConfigurationForTesting else { status = "Save a provider key, model, and base URL first."; return }
        isBenchmarking = true; status = nil
        Task { @MainActor in
            let service = GrammarBenchmarkService(coordinator: GrammarEnsembleCoordinator(remoteClient: StealthGrammarRemoteClient()))
            benchmarkSummary = await service.run(configuration: configuration, strategy: settings.grammarEnsembleStrategy)
            benchmarkComparison = await service.compare(configuration: configuration, strategies: [.fast, .balanced, .thorough, settings.grammarEnsembleStrategy])
            isBenchmarking = false
            reload()
        }
    }
}

@MainActor
final class GrammarDebuggerWindowController: NSWindowController {
    init(settings: SettingsStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        LimaWindowChrome.configure(window, title: "Grammar Debugger", accessibilityLabel: "Lima Grammar Debugger", minSize: NSSize(width: 850, height: 600))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: GrammarDebuggerView(settings: settings)))
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
}
