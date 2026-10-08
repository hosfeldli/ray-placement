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
                AIMemoryInspector(model: model, store: model.workspaceStore, tools: tools)
                if model.hasProviderAPIKey {
                    LimaWorkspaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Suggested actions", systemImage: "sparkles").limaFont(.headline)
                            ForEach(AIWorkspaceAction.allCases.filter { $0.requiresSource }) { action in
                                actionButton(action)
                            }
                            if !model.hasWorkspaceActionSource {
                                Text("Attach context or start a conversation to use these actions.")
                                    .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                            }
                            Text("Adds instructions to your draft without sending.")
                                .limaFont(.caption2).foregroundStyle(LimaTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    LimaWorkspaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Quick prompts", systemImage: "text.bubble").limaFont(.headline)
                            ForEach(AIWorkspaceAction.allCases.filter { !$0.requiresSource }) { action in
                                actionButton(action)
                            }
                        }
                    }
                    LimaWorkspaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Tools & actions", systemImage: "slider.horizontal.3").limaFont(.headline)
                            Picker("Mode", selection: Binding(
                                get: { tools.accessMode },
                                set: { tools.setAccessMode($0) }
                            )) {
                                ForEach(LimaAIToolAccessMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .disabled(model.canEndTask)
                            Text(tools.accessMode.detail)
                                .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                            if tools.accessMode == .custom {
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
                            }
                            Text("Existing grants and computer-action settings still apply.")
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

    private func actionButton(_ action: AIWorkspaceAction) -> some View {
        Button { model.prepareWorkspaceAction(action) } label: {
            Label(action.title, systemImage: action.symbol)
                .limaFont(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!model.aiEnabled || model.canEndTask || (action.requiresSource && !model.hasWorkspaceActionSource))
        .help("Prepare instructions in the composer; review before sending")
    }
}
