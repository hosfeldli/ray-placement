import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
final class ExtensionDevelopmentWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Extension Development"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 760, height: 520)
        window.setAccessibilityLabel("RayPlacement extension development manuals")
        self.init(window: window)
        window.contentView = NSHostingView(rootView: ExtensionDevelopmentView().preferredColorScheme(.dark))
    }

    func present() {
        window?.center()
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ExtensionDevelopmentView: View {
    private let manuals = ExtensionGuide.manuals
    @State private var selectedManualID = ExtensionGuide.manuals.first?.id ?? "builder"
    @State private var selectedSectionID: String?
    @State private var query = ""
    @State private var copiedLabel: String?

    private var manual: ExtensionManual {
        manuals.first { $0.id == selectedManualID } ?? manuals[0]
    }

    private var sections: [ExtensionManualSection] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return manual.sections }
        return manual.sections.filter {
            $0.title.localizedCaseInsensitiveContains(clean)
                || $0.markdown.localizedCaseInsensitiveContains(clean)
        }
    }

    private var selectedSection: ExtensionManualSection {
        if let selectedSectionID,
           let match = manual.sections.first(where: { $0.id == selectedSectionID }) {
            return match
        }
        return sections.first ?? manual.sections[0]
    }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 8) {
                header
                HStack(spacing: 8) {
                    navigation
                    document
                }
            }
            .padding(10)
        }
        .tint(SettingsStore.shared.accentTheme.primary)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                PrismaticPanelShape(cut: 7).fill(SettingsStore.shared.accentTheme.gradient)
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 13, weight: .bold))
            }
            .frame(width: 28, height: 28)
            Text("Extension Lab")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("API 2")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(SettingsStore.shared.accentTheme.tertiary)
            Spacer()
            Button {
                try? ApplicationPaths.prepare()
                NSWorkspace.shared.open(ApplicationPaths.extensions)
            } label: {
                Label("Extensions", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open the installed extensions folder")
            Button(copiedLabel == "Starter" ? "Copied" : "Copy starter") {
                copy(ExtensionGuide.starter, label: "Starter")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .liquidGlass(cornerRadius: 12, depth: .raised, accentOpacity: 0.04)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(manuals) { item in
                    Button {
                        selectedManualID = item.id
                        selectedSectionID = nil
                        query = ""
                    } label: {
                        Text(item.shortTitle)
                            .font(.system(size: 10.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                item.id == selectedManualID
                                    ? AnyShapeStyle(SettingsStore.shared.accentTheme.gradient.opacity(0.22))
                                    : AnyShapeStyle(Color.white.opacity(0.035)),
                                in: PrismaticPanelShape(cut: 5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in manual", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(Color.black.opacity(0.18), in: PrismaticPanelShape(cut: 5))
            .overlay(PrismaticPanelShape(cut: 5).stroke(Color.white.opacity(0.11), lineWidth: 0.6))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        Button {
                            selectedSectionID = section.id
                        } label: {
                            HStack(spacing: 7) {
                                Rectangle()
                                    .fill(section.id == selectedSection.id ? SettingsStore.shared.accentTheme.tertiary : Color.clear)
                                    .frame(width: 1.5, height: 17)
                                Text(section.title)
                                    .font(.system(size: section.level == 1 ? 11.5 : 10.8, weight: section.level == 1 ? .semibold : .medium))
                                    .foregroundStyle(section.id == selectedSection.id ? Color.primary : .secondary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 31)
                            .background(section.id == selectedSection.id ? Color.white.opacity(0.055) : .clear, in: PrismaticPanelShape(cut: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(9)
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .liquidGlass(cornerRadius: 11, depth: .raised, accentOpacity: 0.018)
    }

    private var document: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedSection.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(manual.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(copiedLabel == selectedSection.id ? "Copied" : "Copy section") {
                    copy(selectedSection.markdown, label: selectedSection.id)
                }
                .buttonStyle(.borderless)
                .help("Copy this section as Markdown")
                Button(copiedLabel == manual.id ? "Copied" : "Copy manual") {
                    copy(manual.markdown, label: manual.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .frame(height: 51)

            GlassHairline()

            ScrollView {
                Text(renderedMarkdown(displayMarkdown(selectedSection.markdown)))
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlass(cornerRadius: 12, depth: .floating, accentOpacity: 0.018)
    }

    private func renderedMarkdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }

    private func displayMarkdown(_ source: String) -> String {
        var lines = source.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("#") == true { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedLabel = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedLabel == label { copiedLabel = nil }
        }
    }
}

private struct ExtensionManual: Identifiable {
    let id: String
    let title: String
    let shortTitle: String
    let markdown: String
    let sections: [ExtensionManualSection]
}

private struct ExtensionManualSection: Identifiable {
    let id: String
    let title: String
    let level: Int
    let markdown: String
}

private enum ExtensionGuide {
    static let manuals: [ExtensionManual] = [
        load(resource: "EXTENSIONS", id: "builder", title: "Extension Builder Guide", shortTitle: "BUILD"),
        load(resource: "EXTENSION_AUTHORING_FOR_AI", id: "agent", title: "Coding Agent Contract", shortTitle: "AGENT")
    ]

    static let starter = """
    {
      "schemaVersion": 1,
      "id": "local.example.my-tools",
      "name": "My Tools",
      "commands": [
        {
          "id": "open-projects",
          "title": "Open Projects",
          "keywords": ["code", "folder"],
          "icon": "folder.fill",
          "action": { "type": "file", "value": "~/Projects" }
        }
      ]
    }
    """

    private static func load(
        resource: String,
        id: String,
        title: String,
        shortTitle: String
    ) -> ExtensionManual {
        let markdown = resourceText(resource) ?? fallback
        return ExtensionManual(
            id: id,
            title: title,
            shortTitle: shortTitle,
            markdown: markdown,
            sections: parseSections(markdown, manualID: id)
        )
    }

    private static func resourceText(_ name: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Documentation"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("docs/\(name).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func parseSections(_ markdown: String, manualID: String) -> [ExtensionManualSection] {
        var result: [ExtensionManualSection] = []
        var title = "Overview"
        var level = 1
        var lines: [String] = []

        func appendSection() {
            guard !lines.isEmpty else { return }
            let index = result.count
            result.append(ExtensionManualSection(
                id: "\(manualID)-\(index)",
                title: title,
                level: level,
                markdown: lines.joined(separator: "\n")
            ))
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("# ") || line.hasPrefix("## ") {
                appendSection()
                lines = [line]
                level = line.hasPrefix("## ") ? 2 : 1
                title = line.drop(while: { $0 == "#" || $0 == " " }).description
            } else {
                lines.append(line)
            }
        }
        appendSection()
        return result.isEmpty
            ? [ExtensionManualSection(id: "\(manualID)-0", title: "Overview", level: 1, markdown: markdown)]
            : result
    }

    private static let fallback = """
    # Extension Development

    Create a folder containing `manifest.json`, then use Reload Extensions.

    ## Starter

    Use Copy starter above to begin with the smallest supported manifest.
    """
}
