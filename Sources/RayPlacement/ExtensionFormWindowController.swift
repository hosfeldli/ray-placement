import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
final class ExtensionFormWindowController: NSWindowController {
    private var model: ExtensionFormViewModel?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 620, height: 460)
        window.setAccessibilityLabel("RayPlacement extension workflow")
        self.init(window: window)
    }

    func present(
        command: LoadedExtensionCommand,
        execute: @escaping ([String: String], @escaping (Result<ExtensionExecutor.FormResult, Error>) -> Void) -> Void
    ) {
        guard let definition = command.command.action.form else { return }
        let model = ExtensionFormViewModel(command: command, definition: definition, execute: execute)
        self.model = model
        window?.title = definition.title ?? command.command.title
        window?.contentView = NSHostingView(rootView: ExtensionFormView(model: model))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class ExtensionFormViewModel: ObservableObject {
    enum Phase { case ready, running, finished }

    let command: LoadedExtensionCommand
    let definition: ExtensionFormDefinition
    @Published var values: [String: String]
    @Published var phase: Phase = .ready
    @Published var result: ExtensionExecutor.FormResult?
    @Published var error: String?
    private let execute: ([String: String], @escaping (Result<ExtensionExecutor.FormResult, Error>) -> Void) -> Void

    init(
        command: LoadedExtensionCommand,
        definition: ExtensionFormDefinition,
        execute: @escaping ([String: String], @escaping (Result<ExtensionExecutor.FormResult, Error>) -> Void) -> Void
    ) {
        self.command = command
        self.definition = definition
        values = Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.id, $0.defaultValue ?? "") })
        self.execute = execute
    }

    func binding(for field: ExtensionFormField) -> Binding<String> {
        Binding(
            get: { self.values[field.id, default: ""] },
            set: { self.values[field.id] = $0 }
        )
    }

    func run() {
        phase = .running
        result = nil
        error = nil
        execute(values) { [weak self] result in
            guard let self else { return }
            self.phase = .finished
            switch result {
            case .success(let output): self.result = output
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func copyOutput() {
        guard let output = result?.output else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }
}

private struct ExtensionFormView: View {
    @ObservedObject var model: ExtensionFormViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 0) {
                header
                GlassHairline()
                HSplitView {
                    form
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 390)
                    output
                        .frame(minWidth: 300)
                }
            }
            .padding(10)
        }
        .preferredColorScheme(.dark)
        .tint(SettingsStore.shared.accentTheme.primary)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.command.command.icon ?? "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsStore.shared.accentTheme.gradient)
                .frame(width: 29, height: 29)
                .liquidGlass(cornerRadius: 9, depth: .floating, accentOpacity: 0.1)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.definition.title ?? model.command.command.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if model.command.extensionName != (model.definition.title ?? model.command.command.title) {
                    Text(model.command.extensionName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.phase == .running { ProgressView().controlSize(.small) }
            Button(model.phase == .finished ? "Run Again" : (model.definition.submitLabel ?? "Run")) {
                model.run()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.phase == .running)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .liquidGlass(cornerRadius: 16, depth: .raised, accentOpacity: 0.035)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                ForEach(model.definition.fields) { field in
                    fieldView(field)
                }
            }
            .padding(14)
        }
        .liquidGlass(cornerRadius: 17, depth: .floating, accentOpacity: 0.018)
        .padding(.top, 10)
        .padding(.trailing, 5)
    }

    @ViewBuilder
    private func fieldView(_ field: ExtensionFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.type != .toggle {
                Text(field.label + (field.required == true ? " *" : ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            switch field.type {
            case .text, .number:
                TextField(field.placeholder ?? "", text: model.binding(for: field))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.01)
            case .secure:
                SecureField(field.placeholder ?? "", text: model.binding(for: field))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .liquidGlass(cornerRadius: 9, depth: .recessed, accentOpacity: 0.01)
            case .multiline:
                TextEditor(text: model.binding(for: field))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 110)
                    .liquidGlass(cornerRadius: 10, depth: .recessed, accentOpacity: 0.01)
            case .toggle:
                Toggle(field.label, isOn: Binding(
                    get: { model.values[field.id, default: "false"] == "true" },
                    set: { model.values[field.id] = $0 ? "true" : "false" }
                ))
            case .picker:
                Picker(field.label, selection: model.binding(for: field)) {
                    ForEach(field.options ?? [], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private var output: some View {
        VStack(spacing: 0) {
            HStack {
                if let result = model.result {
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.succeeded ? .green : .orange)
                    Text(result.headline).font(.callout.weight(.semibold))
                    Text(result.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let error = model.error {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption.weight(.medium)).lineLimit(2)
                } else {
                    Image(systemName: model.phase == .running ? "waveform.path.ecg" : "terminal.fill")
                        .foregroundStyle(SettingsStore.shared.accentTheme.primary)
                    Text(model.phase == .running ? "Running…" : "Output")
                        .font(.callout.weight(.semibold))
                }
                Spacer()
                if model.result != nil {
                    Button { model.copyOutput() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain)
                        .help("Copy output")
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            GlassHairline()
            ScrollView(.vertical) {
                Text(model.result?.output ?? (model.phase == .running ? "Waiting for a response…" : "Run this flow to inspect its result."))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(model.result == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
        .liquidGlass(cornerRadius: 17, depth: .floating, accentOpacity: 0.024)
        .padding(.top, 10)
        .padding(.leading, 5)
    }
}
