import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
final class FormatterWindowController: NSWindowController {
    private let model = FormatterWorkspaceModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: "Document Formatter",
            accessibilityLabel: "RayPlacement document formatter",
            minSize: NSSize(width: 760, height: 520)
        )
        self.init(window: window)
        window.contentView = NSHostingView(rootView: LimaTypographyRoot(content: ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            FormatterWorkspaceView(model: model)
                .clipShape(PrismaticPanelShape(cut: 9))
                .padding(10)
        }.preferredColorScheme(.dark)))
    }

    func present() {
        window?.center()
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() { model.reset() }
}

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

    func reset() {
        source = ""
        output = ""
        kind = .automatic
        style = .pretty
        segmentEnding = .detected
        searchQuery = ""
        result = nil
        errorMessage = nil
    }

    private func refreshSearch() {
        searchLines = DocumentFormatterService.search(searchQuery, in: output)
    }
}

struct FormatterWorkspaceView: View {
    @ObservedObject var model: FormatterWorkspaceModel
    @State private var inspectorMode = 0

    var body: some View {
        VStack(spacing: LimaDesign.panelGap) {
            header
            HSplitView {
                editorPane(title: "SOURCE", text: $model.source, editable: true)
                editorPane(title: "FORMATTED", text: $model.output, editable: false)
            }
            inspector
        }
        .padding(LimaDesign.windowPadding)
        .background(Color.clear)
    }

    private var header: some View {
        VStack(spacing: 7) {
            HStack(spacing: LimaDesign.controlGap) {
                LimaToolbarTitle(
                    symbol: "wand.and.stars",
                    title: "Document Formatter",
                    subtitle: "Format, inspect, and copy local documents"
                )
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
                Button { model.format() } label: { Label("Format", systemImage: "wand.and.stars") }
                    .limaButton(prominent: true)
                    .keyboardShortcut(.return, modifiers: [.command])
                Spacer()
                Button("Open File…", action: model.openFile)
                Button("Save…", action: model.saveOutput).disabled(model.output.isEmpty)
            }
            HStack {
                Label(model.statusText, systemImage: statusSymbol)
                    .limaFont(.caption.weight(.medium))
                    .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.horizontal, LimaDesign.toolbarPadding)
        .padding(.vertical, 7)
        .liquidGlass(cornerRadius: LimaDesign.standardCorner, depth: .raised, accentOpacity: 0.018)
    }

    private func editorPane(title: String, text: Binding<String>, editable: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                LimaSectionLabel(title)
                Spacer()
                if !editable {
                    TextField("Search output", text: $model.searchQuery)
                        .limaInputSurface()
                        .frame(width: 150)
                    if !model.searchQuery.isEmpty {
                        Text(model.searchLines.isEmpty ? "No matches" : "Lines \(model.searchLines.prefix(6).map(String.init).joined(separator: ", "))")
                            .limaFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button { model.copyOutput() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(LimaToolbarIconButtonStyle(tint: SettingsStore.shared.accentTheme.primary))
                        .help("Copy formatted output")
                    Button { model.useOutputAsInput() } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(LimaToolbarIconButtonStyle(tint: SettingsStore.shared.accentTheme.primary))
                        .help("Use formatted output as source")
                }
            }
            .padding(.horizontal, LimaDesign.toolbarPadding)
            .frame(height: LimaDesign.compactControlHeight + 4)
            .background(LimaDesign.recessedFill)
            GlassHairline()
            if editable {
                TextEditor(text: text)
                    .limaFont(.system(size: 12.5, design: .monospaced))
                    .padding(6)
                    .accessibilityLabel("Source document")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(text.wrappedValue.isEmpty ? "Formatted output appears here." : text.wrappedValue)
                        .limaFont(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .accessibilityLabel("Formatted document")
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        .background(LimaDesign.editorFill, in: PrismaticPanelShape(cut: LimaDesign.standardCorner))
        .clipShape(PrismaticPanelShape(cut: LimaDesign.standardCorner))
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
                        .limaFont(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, LimaDesign.toolbarPadding)
            .frame(height: LimaDesign.toolbarHeight - 6)
            .background(LimaDesign.recessedFill)
            GlassHairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if inspectorMode == 0 {
                        ForEach(model.result?.diagnostics ?? []) { diagnostic in
                            Label {
                                Text("\(diagnostic.location.map { "\($0) · " } ?? "")\(diagnostic.message)")
                            } icon: {
                                Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(diagnostic.severity == .error ? .red : diagnostic.severity == .warning ? .orange : .green)
                            }
                            .limaFont(.caption)
                        }
                    } else if inspectorMode == 1 {
                        ForEach(Array((model.result?.inspection ?? []).enumerated()), id: \.offset) { _, line in
                            Text(line).limaFont(.caption.monospaced()).textSelection(.enabled)
                        }
                    } else {
                        ForEach(model.result?.edi?.fields ?? []) { field in
                            HStack(alignment: .firstTextBaseline) {
                                Text(field.path).limaFont(.caption.monospaced().bold()).frame(width: 64, alignment: .leading)
                                Text(field.value.isEmpty ? "(empty)" : field.value).limaFont(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Text("segment \(field.segmentIndex)").limaFont(.caption2).foregroundStyle(.tertiary)
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
