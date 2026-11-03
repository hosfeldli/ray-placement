import AppKit
import SwiftUI
import RayPlacementCore

struct ExtensionBuilderView: View {
    let reload: () -> Void
    var created: ((URL) -> Void)? = nil
    @State private var name = "My Extension"
    @State private var identifier = "local.my-extension"
    @State private var template = ExtensionDeveloperKit.Template.script
    @State private var working = false
    @State private var message: String?
    @State private var output: URL?
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Build an extension", systemImage: "hammer.fill").font(.title2.weight(.semibold))
                    Text("Start with a working command, not a blank manifest. No app rebuild or account is required.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("1 · Choose what it does") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Starter", selection: $template) { ForEach(ExtensionDeveloperKit.Template.allCases, id: \.rawValue) { Text($0.title).tag($0) } }
                        Text(template == .aiTool ? "Contribute a working read-only AI text tool using a host adapter. No script or external process is required." : template == .link ? "Open a website from Search. Uses the network capability." : template == .script ? "Run a local executable and show its text output. Includes an executable bin/run starter." : "Collect input in a native form and pass each field as a separate argument to bin/run.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("2 · Give it a stable identity") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
                        TextField("Extension ID", text: $identifier).textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Text("The ID preserves settings and shortcuts across updates. Use letters, numbers, dots and hyphens; for example local.example.my-tools.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("3 · Create, check, and enable") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Creates manifest.json and a quick-start README", systemImage: "doc.text")
                        if [.script, .form].contains(template) { Label("Creates an executable bin/run with safe argument handling", systemImage: "terminal") }
                        Label("Checks the package before linking it into Lima", systemImage: "checkmark.circle")
                        Label("You review its capabilities before it runs", systemImage: "hand.raised")
                    }.font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Create Extension…", action: create).buttonStyle(.borderedProminent).disabled(!valid || working)
                    if working { ProgressView().controlSize(.small) }
                    if let output { Button("Open Source") { NSWorkspace.shared.open(output) }; Button("Review in Library") { created?(output) } .disabled(created == nil) }
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                DisclosureGroup("Developer CLI") {
                    Text("swift run lima-extension init ./my-extension --id local.example.tools --name \"My Tools\" --template form\nswift run lima-extension check ./my-extension\nswift run lima-extension run ./my-extension run message=Hello\nswift run lima-extension pack ./my-extension ./my-extension.zip")
                        .font(.caption.monospaced()).textSelection(.enabled).padding(.top, 8)
                    Text("From the Lima source repository. The app builder above works without command-line tools.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LimaTheme.surfacePrimary)
    }
    private func create() {
        let panel = NSSavePanel(); panel.title = "Create extension folder"; panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = identifier; panel.canCreateDirectories = true; panel.prompt = "Create"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        working = true; let id = identifier, name = name, template = template
        Task { @MainActor in
            defer { working = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ExtensionDeveloperKit.create(at: destination, id: id, name: name, template: template) }.value
                guard result.isValid else { message = result.diagnostics.map(\.message).joined(separator: "\n"); return }
                output = destination
                try await ExtensionLibraryStore.shared.addFolder(destination, link: true)
                message = "Created and linked \(name). Review its capabilities in My Extensions, then enable it. Edit the source folder directly; manifest changes reload while Lima is running."
                reload()
            } catch { message = error.localizedDescription }
        }
    }
}

struct ExtensionDevelopmentView: View {
    @State private var reference = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Extension development", selection: $reference) { Text("Build").tag(false); Text("Reference").tag(true) }
                    .pickerStyle(.segmented).frame(width: 260)
                Spacer()
            }.padding(14)
            if reference { ExtensionReferenceView() }
            else { ExtensionBuilderView(reload: { NotificationCenter.default.post(name: ExtensionDevelopmentFolders.changed, object: nil) }) }
        }.background(LimaTheme.surfacePrimary)
    }
}

struct ExtensionManifestEditor: View {
    let entry: ExtensionLibraryEntry
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original: Data?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(entry.name)").font(.title2.weight(.semibold))
            Text("Saving updates the manifest. Changed capabilities require a fresh review before the extension runs.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).border(LimaTheme.borderSubtle).frame(minHeight: 300)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save & Check", action: save).buttonStyle(.borderedProminent).disabled(original == nil || entry.bundled) }
        }.padding(20).frame(width: 680, height: 520)
        .onAppear {
            do {
                let attributes = try entry.manifestURL.resourceValues(forKeys: [.fileSizeKey])
                guard (attributes.fileSize ?? Int.max) <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: entry.manifestURL)
                guard let string = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                text = string; original = data
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        do {
            guard text.utf8.count <= 2_000_000, let data = text.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
            try manifest.validateLifecycleMetadata()
            guard (1...3).contains(manifest.schemaVersion), !manifest.id.isEmpty,
                  !manifest.bundled, manifest.provenance != .bundled, manifest.trust != .bundled, manifest.trust != .builtIn else {
                error = "Use a supported user-extension manifest; editing cannot grant built-in trust."; return
            }
            guard try Data(contentsOf: entry.manifestURL) == original else { error = "This file changed in another editor. Cancel and reopen it before saving."; return }
            try data.write(to: entry.manifestURL, options: .atomic)
            saved(); NotificationCenter.default.post(name: ExtensionDevelopmentFolders.changed, object: nil); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
