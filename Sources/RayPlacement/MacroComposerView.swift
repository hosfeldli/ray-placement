import SwiftUI

@MainActor
struct MacroComposerView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject private var store = LimaMacroStore.shared
    @State private var name = ""
    @State private var selectedCommandID = ""
    @State private var failurePolicy: LimaMacroFailurePolicy = .stop
    @State private var steps: [LimaActionStep] = []

    private var extensionCommands: [ManagedCommandDescriptor] {
        viewModel.commandDescriptors.filter { $0.id.hasPrefix("extension.") }
    }

    var body: some View {
        Section("Action-chain composer") {
            Text("Compose safe macros from registered extension commands. Arbitrary shell text is never accepted.")
                .foregroundStyle(.secondary)
                .limaFont(.caption)
            TextField("Macro name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Command", selection: $selectedCommandID) {
                    Text("Choose a registered command").tag("")
                    ForEach(extensionCommands) { command in
                        Text(command.title).tag(command.id)
                    }
                }
                Button("Add Step") { addStep() }
                    .disabled(selectedCommandID.isEmpty || steps.count >= 8)
            }
            Picker("On failure", selection: $failurePolicy) {
                Text("Stop").tag(LimaMacroFailurePolicy.stop)
                Text("Continue").tag(LimaMacroFailurePolicy.continueOnFailure)
            }
            .pickerStyle(.segmented)
            if steps.isEmpty {
                Text("No steps yet.").foregroundStyle(.secondary).limaFont(.caption)
            } else {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 22)
                        Text(step.title)
                        Spacer()
                        Button { steps.removeAll { $0.id == step.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Button("Save Macro") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || steps.isEmpty)
                if !store.chains.isEmpty {
                    Text("\(store.chains.count) saved")
                        .foregroundStyle(.secondary)
                        .limaFont(.caption)
                }
            }
        }
    }

    private func addStep() {
        guard let command = extensionCommands.first(where: { $0.id == selectedCommandID }) else { return }
        steps.append(LimaActionStep(commandID: command.id, title: command.title))
        selectedCommandID = ""
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !steps.isEmpty else { return }
        store.save(LimaActionChain(name: cleanName, steps: steps, failurePolicy: failurePolicy))
        name = ""
        steps = []
        failurePolicy = .stop
    }
}
