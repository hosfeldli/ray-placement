import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
final class FormatterWorkspaceModel: ObservableObject {
    enum SegmentEnding: String, CaseIterable, Identifiable {
        case detected
        case tilde
        case newline
        case caret
        case pipe

        var id: String { rawValue }
        var title: String {
            switch self {
            case .detected: return "Keep detected"
            case .tilde: return "~ (tilde)"
            case .newline: return "New line"
            case .caret: return "^ (caret)"
            case .pipe: return "| (pipe)"
            }
        }
        var delimiter: Character? {
            switch self {
            case .detected: return nil
            case .tilde: return "~"
            case .newline: return "\n"
            case .caret: return "^"
            case .pipe: return "|"
            }
        }
    }

    @Published var source = ""
    @Published var output = ""
    @Published var kind: FormatterDocumentKind = .automatic
    @Published var style: FormatterOutputStyle = .pretty
    @Published var segmentEnding: SegmentEnding = .detected
    @Published var searchQuery = "" { didSet { refreshSearch() } }
    @Published private(set) var searchLines: [Int] = []
    @Published private(set) var result: DocumentFormatResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isProposing = false
    @Published private(set) var proposal: String?
    @Published private(set) var progressText = ""

    private let runner = WritingProviderRunner()
    private let maximumCharacters = 1_000_000

    var statusText: String {
        if let errorMessage { return errorMessage }
        guard let result else { return "Temporary workspace · nothing is saved to Notes" }
        let errors = result.diagnostics.filter { $0.severity == .error }.count
        let warnings = result.diagnostics.filter { $0.severity == .warning }.count
        if errors > 0 { return "\(errors) validation error\(errors == 1 ? "" : "s") · \(warnings) warning\(warnings == 1 ? "" : "s")" }
        return warnings > 0 ? "Valid structure · \(warnings) warning\(warnings == 1 ? "" : "s")" : "Valid \(result.kind.title) · ready to copy or save"
    }

    func format() {
        do {
            let formatted = try DocumentFormatterService.format(
                source,
                kind: kind,
                style: style,
                ediSegmentDelimiter: segmentEnding.delimiter
            )
            result = formatted
            output = formatted.output
            errorMessage = nil
            proposal = nil
            if kind == .automatic { kind = formatted.kind }
            refreshSearch()
        } catch {
            result = nil
            output = ""
            errorMessage = error.localizedDescription
            refreshSearch()
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Open a document to format"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 10_000_000 else {
                errorMessage = "Formatter files are limited to 10 MB so Notes stays responsive."
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.count <= maximumCharacters else {
                errorMessage = "Formatter text is limited to \(maximumCharacters.formatted()) characters."
                return
            }
            source = text
            kind = DocumentFormatterService.detectKind(text)
            format()
        } catch {
            errorMessage = "Could not open the file: \(error.localizedDescription)"
        }
    }

    func saveOutput() {
        guard !output.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Save formatted document"
        panel.nameFieldStringValue = "formatted.\(result?.kind.rawValue ?? "txt")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the output: \(error.localizedDescription)"
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    func useOutputAsInput() {
        guard !output.isEmpty else { return }
        source = output
        format()
    }

    func proposeCorrections() {
        guard let result, !source.isEmpty else { return }
        guard source.count <= 18_000 else {
            errorMessage = "Local AI proposals are limited to 18,000 characters. Formatting, validation, inspection, search, and file export still support the full document."
            return
        }
        isProposing = true
        progressText = "Preparing a local AI review…"
        errorMessage = nil
        requestProposal(for: source, baseline: result, pass: 1)
    }

    private func requestProposal(
        for candidateSource: String,
        baseline: DocumentFormatResult,
        pass: Int
    ) {
        runner.proposeDocumentCorrection(
            source: candidateSource,
            kind: baseline.kind,
            diagnostics: baseline.diagnostics,
            progress: { [weak self] message in
                self?.progressText = pass == 1 ? message : "Verification pass \(pass) · \(message)"
            }
        ) { [weak self] response in
            guard let self else { return }
            switch response {
            case .success(let text):
                let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateResult = try? DocumentFormatterService.format(
                    candidate,
                    kind: baseline.kind,
                    style: self.style,
                    ediSegmentDelimiter: self.segmentEnding.delimiter
                )
                let currentErrors = baseline.diagnostics.filter { $0.severity == .error }.count
                let proposedErrors = candidateResult?.diagnostics.filter { $0.severity == .error }.count ?? Int.max

                if proposedErrors > 0,
                   proposedErrors < currentErrors,
                   pass < 2,
                   let candidateResult {
                    self.progressText = "Pass 1 improved the document · checking the remaining finding…"
                    self.requestProposal(for: candidate, baseline: candidateResult, pass: pass + 1)
                    return
                }

                self.isProposing = false
                guard proposedErrors == 0 else {
                    self.errorMessage = "The selected model did not resolve every validation error. The original remains unchanged; try the Quality model or edit the explicit validation findings manually."
                    self.progressText = "Proposal rejected by deterministic validation"
                    return
                }
                self.proposal = candidate
                self.progressText = "Proposal ready · review before applying"
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.progressText = ""
            }
        }
    }

    func cancelProposal() {
        runner.cancel()
        isProposing = false
        progressText = ""
    }

    func applyProposal() {
        guard let proposal else { return }
        source = proposal
        self.proposal = nil
        format()
    }

    func dismissProposal() { proposal = nil }

    func reset() {
        runner.cancel()
        source = ""
        output = ""
        kind = .automatic
        style = .pretty
        segmentEnding = .detected
        searchQuery = ""
        result = nil
        errorMessage = nil
        proposal = nil
        isProposing = false
        progressText = ""
    }

    private func refreshSearch() {
        searchLines = DocumentFormatterService.search(searchQuery, in: output)
    }
}

struct FormatterWorkspaceView: View {
    @ObservedObject var model: FormatterWorkspaceModel
    @State private var inspectorMode = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                editorPane(title: "SOURCE", text: $model.source, editable: true)
                editorPane(title: "FORMATTED", text: $model.output, editable: false)
            }
            Divider()
            inspector
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Picker("Format", selection: $model.kind) {
                    ForEach(FormatterDocumentKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 150)
                Picker("Style", selection: $model.style) {
                    ForEach(FormatterOutputStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 130)
                if model.kind == .edi {
                    Picker("Segment ending", selection: $model.segmentEnding) {
                        ForEach(FormatterWorkspaceModel.SegmentEnding.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 170)
                }
                Button { model.format() } label: { Label("Format & Validate", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                Spacer()
                Button("Open File…", action: model.openFile)
                Button("Save…", action: model.saveOutput).disabled(model.output.isEmpty)
            }
            HStack {
                Label(model.statusText, systemImage: statusSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                Spacer()
                if model.isProposing {
                    ProgressView().controlSize(.small)
                    Text(model.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel", action: model.cancelProposal)
                } else {
                    Button { model.proposeCorrections() } label: {
                        Label("AI Propose Corrections", systemImage: "sparkles")
                    }
                    .disabled(model.result == nil)
                    .help("Ask the selected local Formatter model to propose a complete corrected document")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func editorPane(title: String, text: Binding<String>, editable: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption2.bold()).tracking(1.1).foregroundStyle(.secondary)
                Spacer()
                if editable {
                    Text("Temporary · up to 1,000,000 characters").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    TextField("Search output", text: $model.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    if !model.searchQuery.isEmpty {
                        Text(model.searchLines.isEmpty ? "No matches" : "Lines \(model.searchLines.prefix(6).map(String.init).joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button { model.copyOutput() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy formatted output")
                    Button { model.useOutputAsInput() } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(.borderless).help("Use formatted output as source")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            if editable {
                TextEditor(text: text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(6)
                    .accessibilityLabel("Source document")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(text.wrappedValue.isEmpty ? "Formatted output appears here." : text.wrappedValue)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .accessibilityLabel("Formatted document")
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Inspector", selection: $inspectorMode) {
                    Text("Validation").tag(0)
                    Text("Structure").tag(1)
                    if model.result?.edi != nil { Text("EDI Fields").tag(2) }
                }
                .pickerStyle(.segmented)
                .frame(width: model.result?.edi == nil ? 220 : 320)
                Spacer()
                if let edi = model.result?.edi {
                    Text("Elements \(edi.elementDelimiter.description) · Segments \(delimiterName(edi.segmentDelimiter)) · \(edi.segmentCount) segments")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if let proposal = model.proposal {
                        proposalCard(proposal)
                    }
                    if inspectorMode == 0 {
                        ForEach(model.result?.diagnostics ?? []) { diagnostic in
                            Label {
                                Text("\(diagnostic.location.map { "\($0) · " } ?? "")\(diagnostic.message)")
                            } icon: {
                                Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(diagnostic.severity == .error ? .red : diagnostic.severity == .warning ? .orange : .green)
                            }
                            .font(.caption)
                        }
                    } else if inspectorMode == 1 {
                        ForEach(Array((model.result?.inspection ?? []).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } else {
                        ForEach(model.result?.edi?.fields ?? []) { field in
                            HStack(alignment: .firstTextBaseline) {
                                Text(field.path).font(.caption.monospaced().bold()).frame(width: 64, alignment: .leading)
                                Text(field.value.isEmpty ? "(empty)" : field.value).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Text("segment \(field.segmentIndex)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .frame(minHeight: 155, idealHeight: 190, maxHeight: 250)
    }

    private func proposalCard(_ proposal: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Local AI proposal", systemImage: "sparkles").font(.caption.bold())
                Spacer()
                Button("Dismiss", action: model.dismissProposal)
                Button("Apply & Validate", action: model.applyProposal).buttonStyle(.borderedProminent)
            }
            Text(proposal).font(.caption.monospaced()).lineLimit(5).textSelection(.enabled)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var statusSymbol: String {
        if model.errorMessage != nil { return "exclamationmark.triangle.fill" }
        if model.result == nil { return "clock.badge" }
        return model.result?.isValid == true ? "checkmark.seal.fill" : "checklist.unchecked"
    }

    private func delimiterName(_ delimiter: Character) -> String {
        if delimiter == "\n" { return "LF" }
        if delimiter == "\r" { return "CR" }
        return delimiter.description
    }
}
