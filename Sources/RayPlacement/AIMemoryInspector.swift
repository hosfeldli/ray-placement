import SwiftUI

/// Explicit user controls for local memory. AI may read enabled entries but never mutates them.
@MainActor
struct AIMemoryInspector: View {
    @ObservedObject var model: AIChatViewModel
    @ObservedObject var store: AIWorkspaceStore
    @ObservedObject var tools: LimaAIToolStore
    @State private var expanded = false
    @State private var query = ""
    @State private var editing: AIMemory?
    @State private var deleting: AIMemory?
    @State private var adding = false

    init(model: AIChatViewModel, store: AIWorkspaceStore, tools: LimaAIToolStore, initiallyExpanded: Bool = false) {
        self.model = model
        self.store = store
        self.tools = tools
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var visible: [AIMemory] {
        store.memories(for: model.selectedConversation?.projectID)
    }

    private var filtered: [AIMemory] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.filter { clean.isEmpty || ($0.title + " " + $0.content).localizedStandardContains(clean) }
    }

    var body: some View {
        LimaWorkspaceCard {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tools.enabledToolIDs.contains("memory_search")
                         ? "AI can read these saved entries when you send. Add, edit, or forget entries yourself; earlier messages may still contain previously shared context."
                         : "Memory read is off. Saved entries remain here for review and direct editing.")
                        .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        adding = true
                    } label: {
                        Label("Add memory", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.canEndTask)
                    if !visible.isEmpty {
                        TextField("Filter memories", text: $query).textFieldStyle(.roundedBorder)
                    }
                    if filtered.isEmpty {
                        Text(visible.isEmpty ? "No saved memories in this scope." : "No matching memories.")
                            .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                    }
                    ForEach(filtered) { memory in
                        memoryRow(memory)
                    }
                    if let error = store.lastError {
                        Text(error).limaFont(.caption).foregroundStyle(LimaColors.danger)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Memory · \(visible.count)", systemImage: "brain.head.profile")
                    .limaFont(.headline)
            }
        }
        .sheet(isPresented: $adding) {
            AIMemoryCreateSheet(model: model)
        }
        .sheet(item: $editing) { memory in
            AIMemoryEditSheet(model: model, memory: memory)
        }
        .alert("Forget this memory?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Forget", role: .destructive) {
                if let memory = deleting { model.forgetMemory(memory.id) }
                deleting = nil
            }
        } message: {
            Text("Remove the saved entry. This does not erase context already sent in earlier messages.")
        }
    }

    private func memoryRow(_ memory: AIMemory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(memory.title.isEmpty ? "Memory" : memory.title)
                    .limaFont(.callout.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Menu {
                    Button("Edit…") { editing = memory }
                    Button("Forget…", role: .destructive) { deleting = memory }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.canEndTask)
                .accessibilityLabel("Actions for " + memory.title)
            }
            Text(memory.projectID == nil ? "Global" : "This project")
                .limaFont(.caption2).foregroundStyle(LimaTheme.accentInk)
            Text(memory.content).limaFont(.caption)
                .foregroundStyle(LimaTheme.textSecondary).lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 9))
    }
}

@MainActor
private struct AIMemoryEditSheet: View {
    @ObservedObject var model: AIChatViewModel
    let memory: AIMemory
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var failed = false

    init(model: AIChatViewModel, memory: AIMemory) {
        self.model = model
        self.memory = memory
        _title = State(initialValue: memory.title)
        _content = State(initialValue: memory.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit memory").limaFont(.title3.weight(.semibold))
            Text(memory.projectID == nil ? "Global user context" : "Current project context")
                .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $content).frame(minHeight: 150)
            if failed {
                Text("This memory is no longer available in the current scope.")
                    .limaFont(.caption).foregroundStyle(LimaColors.danger)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if model.updateMemory(memory.id, title: title, content: content) { dismiss() }
                    else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.canEndTask || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || content.count > AIWorkspaceStore.maximumMemoryCharacters
                          || title.count > AIWorkspaceStore.maximumMemoryTitleCharacters)
            }
        }
        .padding(20).frame(width: 420)
    }
}

@MainActor
private struct AIMemoryCreateSheet: View {
    @ObservedObject var model: AIChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var failed = false

    private var scopeLabel: String {
        model.selectedConversation?.projectID == nil ? "Global user context" : "Current project context"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add memory").limaFont(.title3.weight(.semibold))
            Text(scopeLabel).limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
            Text("Only you can save, edit, or forget local memory. AI can read it only when the Memory capability is enabled.")
                .limaFont(.caption).foregroundStyle(LimaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $content).frame(minHeight: 150)
            if failed {
                Text(model.workspaceStore.lastError ?? "Memory could not be saved.")
                    .limaFont(.caption).foregroundStyle(LimaColors.danger)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    if model.saveMemory(title: title, content: content) != nil { dismiss() }
                    else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.canEndTask || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || content.count > AIWorkspaceStore.maximumMemoryCharacters
                          || title.count > AIWorkspaceStore.maximumMemoryTitleCharacters)
            }
        }
        .padding(20).frame(width: 440)
    }
}
