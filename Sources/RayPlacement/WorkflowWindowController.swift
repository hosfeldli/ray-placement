import AppKit
import RayPlacementCore
import SwiftUI

@MainActor
final class WorkflowWindowController: NSWindowController {
    private var model: WorkflowEditorModel?
    private let execute: (WorkflowDefinition) -> Void

    init(execute: @escaping (WorkflowDefinition) -> Void) {
        self.execute = execute
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        LimaWindowChrome.configure(
            window,
            title: "Workflows",
            accessibilityLabel: "Lima workflows",
            minSize: NSSize(width: 620, height: 420)
        )
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func present(selected workflow: WorkflowDefinition? = nil) {
        let model = WorkflowEditorModel(selected: workflow)
        model.onExecute = { [weak self] workflow in
            self?.execute(workflow)
        }
        self.model = model
        window?.contentView = NSHostingView(rootView: LimaTypographyRoot(content: WorkflowEditorView(model: model)))
        window?.center()
        if let window { WorkspaceWindowCoordinator.shared.present(window) }
    }

    func shutdown() {
        window?.orderOut(nil)
        model = nil
    }
}

@MainActor
private final class WorkflowEditorModel: ObservableObject {
    @Published var workflows: [WorkflowDefinition] = []
    @Published var selectedID: UUID?
    @Published var commandFilter = ""
    @Published var error: String?
    var onExecute: ((WorkflowDefinition) -> Void)?

    init(selected: WorkflowDefinition?) {
        workflows = WorkflowStore.shared.workflows
        selectedID = selected?.id ?? workflows.first?.id
        if let selected, !workflows.contains(where: { $0.id == selected.id }) {
            workflows.insert(selected, at: 0)
            selectedID = selected.id
        }
    }

    var selected: WorkflowDefinition? {
        workflows.first { $0.id == selectedID }
    }

    var availableCommands: [LoadedExtensionCommand] {
        let commands = ExtensionLoader().load().commands
        let query = commandFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return commands }
        return commands.filter {
            $0.command.title.localizedCaseInsensitiveContains(query)
                || $0.extensionName.localizedCaseInsensitiveContains(query)
                || $0.command.id.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh() {
        workflows = WorkflowStore.shared.workflows
        if selectedID == nil || !workflows.contains(where: { $0.id == selectedID }) {
            selectedID = workflows.first?.id
        }
    }

    func create() {
        let workflow = WorkflowStore.shared.create()
        refresh()
        selectedID = workflow.id
    }

    func deleteSelected() {
        guard let selected else { return }
        WorkflowStore.shared.delete(selected)
        refresh()
    }

    func toggleFavorite() {
        guard let selected else { return }
        WorkflowStore.shared.toggleFavorite(selected)
        refresh()
    }

    func updateSelected(_ mutate: (inout WorkflowDefinition) -> Void) {
        guard let selected, let index = workflows.firstIndex(where: { $0.id == selected.id }) else { return }
        var updated = selected
        mutate(&updated)
        workflows[index] = updated
        WorkflowStore.shared.update(updated)
    }

    func addCommand(_ command: LoadedExtensionCommand) {
        updateSelected { workflow in
            let commandID = "extension.\(command.extensionID).\(command.command.id)"
            workflow.steps.append(.init(commandID: commandID))
        }
    }

    func removeStep(_ step: WorkflowDefinition.Step) {
        updateSelected { workflow in workflow.steps.removeAll { $0.id == step.id } }
    }

    func moveStep(_ step: WorkflowDefinition.Step, by offset: Int) {
        updateSelected { workflow in
            guard let index = workflow.steps.firstIndex(where: { $0.id == step.id }) else { return }
            let target = index + offset
            guard workflow.steps.indices.contains(target) else { return }
            workflow.steps.swapAt(index, target)
        }
    }

    func setContinueOnFailure(_ value: Bool, for step: WorkflowDefinition.Step) {
        updateSelected { workflow in
            guard let index = workflow.steps.firstIndex(where: { $0.id == step.id }) else { return }
            workflow.steps[index].continueOnFailure = value
        }
    }

    func executeSelected() {
        guard let selected else { return }
        onExecute?(selected)
    }
}

private struct WorkflowEditorView: View {
    @ObservedObject var model: WorkflowEditorModel
    @ObservedObject private var store = WorkflowStore.shared

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(material: .underWindowBackground, blendingMode: .behindWindow)
            VStack(spacing: 10) {
                toolbar
                GlassHairline()
                HSplitView {
                    workflowList
                        .frame(minWidth: 205, idealWidth: 230, maxWidth: 280)
                    editor
                        .frame(minWidth: 350)
                }
            }
            .padding(LimaDesign.windowPadding)
        }
        .tint(SettingsStore.shared.accentTheme.readablePrimary)
        .onReceive(store.$workflows) { _ in model.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            LimaToolbarTitle(symbol: "arrow.trianglehead.2.clockwise.rotate.90", title: "Workflows", subtitle: "Build repeatable command sequences")
            Spacer()
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            }
            Button { model.create() } label: { Label("New", systemImage: "plus") }
                .limaButton(prominent: true)
                .controlSize(.small)
        }
        .padding(.horizontal, LimaDesign.toolbarPadding)
        .frame(height: LimaDesign.toolbarHeight)
        .liquidGlass(cornerRadius: LimaDesign.standardCorner, depth: .raised, accentOpacity: 0.022)
    }

    private var workflowList: some View {
        VStack(spacing: 7) {
            if model.workflows.isEmpty {
                EmptyWorkflowState(title: "No workflows", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", message: "Create a workflow to chain Lima commands.")
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.workflows) { workflow in
                        HStack(spacing: 8) {
                            Image(systemName: workflow.favorite ? "star.fill" : "arrow.trianglehead.2.clockwise.rotate.90")
                                .foregroundStyle(workflow.favorite ? .yellow : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workflow.name).lineLimit(1)
                                Text("\(workflow.steps.count) step\(workflow.steps.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(workflow.id)
                        .contextMenu {
                            Button(workflow.favorite ? "Remove Favorite" : "Favorite") {
                                model.selectedID = workflow.id
                                model.toggleFavorite()
                            }
                            Button("Delete", role: .destructive) {
                                model.selectedID = workflow.id
                                model.deleteSelected()
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .liquidGlass(cornerRadius: 14, depth: .floating, accentOpacity: 0.014)
    }

    @ViewBuilder
    private var editor: some View {
        if let workflow = model.selected {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    TextField("Workflow name", text: Binding(
                        get: { workflow.name },
                        set: { newValue in model.updateSelected { $0.name = newValue } }
                    ))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    Button { model.toggleFavorite() } label: {
                        Image(systemName: workflow.favorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(workflow.favorite ? .yellow : .secondary)
                    Button { model.executeSelected() } label: { Label("Run", systemImage: "play.fill") }
                        .limaButton(prominent: true)
                        .controlSize(.small)
                    Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
                Text("Steps run from top to bottom. Enable Continue on failure when a failed step should not stop the workflow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if workflow.steps.isEmpty {
                    EmptyWorkflowState(title: "No steps", systemImage: "list.number", message: "Add a command from the panel below.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                            stepRow(step, index: index, count: workflow.steps.count)
                        }
                    }
                    .listStyle(.inset)
                }

                HStack(spacing: 7) {
                    TextField("Filter commands", text: $model.commandFilter)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        ForEach(model.availableCommands, id: \.command.id) { command in
                            Button("\(command.command.title) · \(command.extensionName)") {
                                model.addCommand(command)
                            }
                        }
                    } label: {
                        Label("Add command", systemImage: "plus.circle")
                    }
                    .disabled(model.availableCommands.isEmpty)
                }
            }
            .padding(13)
        } else {
            EmptyWorkflowState(title: "Select a workflow", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", message: "Create or select a workflow to edit it.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stepRow(_ step: WorkflowDefinition.Step, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: step.commandID)).lineLimit(1)
                Text(step.commandID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("Continue", isOn: Binding(
                get: { step.continueOnFailure },
                set: { model.setContinueOnFailure($0, for: step) }
            ))
            .toggleStyle(.checkbox)
            Button { model.moveStep(step, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(index == 0)
            Button { model.moveStep(step, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(index == count - 1)
            Button(role: .destructive) { model.removeStep(step) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func displayName(for id: String) -> String {
        model.availableCommands.first { "extension.\($0.extensionID).\($0.command.id)" == id || $0.command.id == id }?.command.title ?? id
    }
}


private struct EmptyWorkflowState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 27))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }
}
