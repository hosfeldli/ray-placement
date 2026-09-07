import Foundation
import RayPlacementCore

@MainActor
final class WorkflowStore: ObservableObject {
    static let shared = WorkflowStore()

    @Published private(set) var workflows: [WorkflowDefinition]
    @Published var lastError: String?
    private let url = ApplicationPaths.applicationSupport.appendingPathComponent("workflows.json")
    private let store = PrivateFileStore()

    private init() {
        let loaded = store.loadJSON([WorkflowDefinition].self, from: url)
        workflows = loaded.value ?? []
        if loaded.result.state == .corrupt || loaded.result.state == .unreadable {
            lastError = "Workflows could not be loaded. A recovery copy was preserved."
        }
    }

    func create(name: String = "New Workflow") -> WorkflowDefinition {
        let workflow = WorkflowDefinition(name: name)
        workflows.insert(workflow, at: 0)
        save()
        return workflow
    }

    func update(_ workflow: WorkflowDefinition) {
        guard let index = workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
        workflows[index] = workflow
        save()
    }

    func delete(_ workflow: WorkflowDefinition) {
        workflows.removeAll { $0.id == workflow.id }
        save()
    }

    func toggleFavorite(_ workflow: WorkflowDefinition) {
        var updated = workflow
        updated.favorite.toggle()
        update(updated)
    }

    private func save() {
        do {
            try ApplicationPaths.prepare()
            try store.write(workflows, to: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

@MainActor
struct WorkflowExecutor {
    struct ConfirmationRequired: Error {}

    func execute(
        _ workflow: WorkflowDefinition,
        confirm: Bool,
        run: @escaping @MainActor (String) async throws -> Void
    ) async -> WorkflowExecutionReport {
        let startedAt = Date()
        var results: [WorkflowExecutionReport.StepResult] = []

        for step in workflow.steps {
            do {
                if !confirm { throw ConfirmationRequired() }
                try await run(step.commandID)
                results.append(.init(commandID: step.commandID, succeeded: true))
            } catch {
                results.append(.init(commandID: step.commandID, succeeded: false, message: error.localizedDescription))
                if !step.continueOnFailure { break }
            }
        }

        return WorkflowExecutionReport(
            workflowID: workflow.id,
            startedAt: startedAt,
            finishedAt: Date(),
            steps: results
        )
    }
}
