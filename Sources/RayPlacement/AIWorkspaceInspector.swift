import SwiftUI
import RayPlacementCore

/// Context is user-selected and remains a draft until Send. Capability switches
/// use the same store and execution policy as the existing composer menu.
@MainActor
struct AIWorkspaceInspector: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject var notes: NotesStore
    @ObservedObject var tools: LimaAIToolStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LimaWorkspaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Context", systemImage: "doc.on.doc").limaFont(.headline)
                            Spacer()
                            Button("Clear") { model.attachments.removeAll() }
                                .buttonStyle(.borderless).limaFont(.caption)
                                .disabled(model.attachments.isEmpty || model.canEndTask)
                                .help("Remove all attachments from this draft")
                        }
                        if model.attachments.isEmpty {
                            Text("Add a note, file, or text to your next message.")
                                .limaFont(.callout).foregroundStyle(LimaTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.attachments) { attachment in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: attachment.kind.symbol).foregroundStyle(LimaTheme.accentInk)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(attachment.displayName).limaFont(.callout.weight(.medium)).lineLimit(2)
                                    Text(attachment.preview).limaFont(.caption)
                                        .foregroundStyle(LimaTheme.textSecondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Button { model.remove(attachment) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove " + attachment.displayName)
                                    .disabled(model.canEndTask)
                            }
                            .padding(10)
                            .background(LimaTheme.surfaceSelected, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Menu {
                            Button("Files…", action: model.addFiles)
                            Button("Clipboard", action: model.addClipboard)
                            Button("Current selection", action: model.addSelection)
                            if !notes.notes.isEmpty {
                                Menu("Local note") {
                                    ForEach(notes.notes) { note in
                                        Button(note.displayTitle) { model.prepareNoteDraft(note, prompt: "") }
                                    }
                                }
                            }
                        } label: {
                            Label("Add context", systemImage: "plus")
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(model.canEndTask)
                        Text("Only included when you send this draft.")
                            .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                    }
                }
                if model.hasProviderAPIKey {
                    LimaWorkspaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Suggested actions", systemImage: "sparkles").limaFont(.headline)
                            prompt("Summarize", detail: "Create a concise overview", symbol: "text.alignleft",
                                   text: "Summarize the attached context clearly and concisely.")
                            prompt("Improve writing", detail: "Keep the original meaning", symbol: "wand.and.stars",
                                   text: "Improve the clarity of the attached text while preserving its meaning.")
                            prompt("Find action items", detail: "Prepare a task list", symbol: "checklist",
                                   text: "Extract action items from the attached context as a Markdown checklist. Do not invent owners or dates.")
                            Text("Adds instructions to your draft without sending.")
                                .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    LimaWorkspaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Tools & actions", systemImage: "slider.horizontal.3").limaFont(.headline)
                            ForEach(LimaAIToolGroup.visibleGroups(for: LimaAIToolRegistry.availableDefinitions)) { group in
                                Toggle(isOn: Binding(
                                    get: { tools.isEnabled(group) },
                                    set: { tools.setEnabled(group, enabled: $0) }
                                )) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label(group.title, systemImage: group.symbol).limaFont(.callout.weight(.medium))
                                        Text(group.summary).limaFont(.caption)
                                            .foregroundStyle(LimaTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .toggleStyle(.switch).controlSize(.small)
                                .disabled(model.canEndTask)
                            }
                            Text("Existing grants and tool restrictions still apply.")
                                .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(LimaTheme.surfaceSecondary)
        .accessibilityIdentifier("lima-ai-context-inspector")
    }

    private func prompt(_ title: String, detail: String, symbol: String, text: String) -> some View {
        LimaWorkspaceActionRow(title: title, detail: detail, symbol: symbol) {
            model.appendDraftPrompt(text)
        }
        .disabled(model.canEndTask || model.attachments.isEmpty)
    }
}
