import Foundation
import SwiftUI

struct AITaskPlanStep: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", completed, blocked }
    let id: String
    var title: String
    var status: Status
    var evidence: String
}

struct AITaskPlan: Codable, Hashable, Sendable {
    var revision: Int
    var steps: [AITaskPlanStep]
    var completedCount: Int { steps.filter { $0.status == .completed }.count }
    var unfinished: [AITaskPlanStep] { steps.filter { $0.status != .completed } }
    var continuationReminder: String? {
        guard !unfinished.isEmpty, !unfinished.contains(where: { $0.status == .blocked }) else { return nil }
        return "Your saved checklist still has unfinished work: " + unfinished.map { "\($0.id): \($0.title) [\($0.status.rawValue)]" }.joined(separator: "; ") + ". Continue the requested work. Use update_task_plan as each step changes. Check results before completing a step; report a real blocker instead of claiming completion."
    }
}

enum AITaskPlanTool {
    static let id = "update_task_plan"
    static let definition = LimaAIToolDefinition(id: id, name: id,
        description: "Maintain the visible checklist for this assistant turn. For multi-step work, create a short plan before acting, keep one step in_progress, then check off each step after verifying its result. Reuse stable IDs and expected_revision (0 initially). Completion needs brief evidence and a previously in_progress step. Explain any scope or order changes. A blocked step needs a reason. This updates local progress only; it does not execute the work.",
        parameters: ["type": "object", "properties": [
            "expected_revision": ["type": "integer", "minimum": 0],
            "reason": ["type": "string"],
            "steps": ["type": "array", "minItems": 1, "maxItems": 12, "items": [
                "type": "object", "properties": [
                    "id": ["type": "string"],
                    "title": ["type": "string"],
                    "status": ["type": "string", "enum": ["pending", "in_progress", "completed", "blocked"]],
                    "evidence": ["type": "string"]
                ], "required": ["id", "title", "status", "evidence"], "additionalProperties": false]
            ]
        ], "required": ["expected_revision", "reason", "steps"], "additionalProperties": false], risk: .read)

    struct Update: Decodable { let expected_revision: Int; let reason: String; let steps: [AITaskPlanStep] }
    static func apply(_ data: Data, to previous: AITaskPlan?) throws -> AITaskPlan {
        guard data.count <= 64_000 else {
            throw NSError(domain: "LimaTaskPlan", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Keep the task plan under 64000 bytes."])
        }
        let update = try JSONDecoder().decode(Update.self, from: data)
        func reject(_ message: String) throws -> Never { throw NSError(domain: "LimaTaskPlan", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard update.expected_revision == (previous?.revision ?? 0) else { try reject("Read the returned checklist revision before updating it.") }
        guard (1...12).contains(update.steps.count), update.reason.count <= 400,
              Set(update.steps.map(\.id)).count == update.steps.count,
              update.steps.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 48 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 200 && $0.evidence.count <= 400 }),
              update.steps.filter({ $0.status == .inProgress }).count <= 1 else { try reject("Use 1–12 distinct tasks and at most one in-progress step, with short titles and evidence.") }
        for step in update.steps {
            let old = previous?.steps.first { $0.id == step.id }
            if step.status == .completed && old?.status != .completed {
                guard old?.status == .inProgress, !step.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { try reject("Start a step before completing it and include evidence of its result.") }
            }
            if step.status == .blocked && step.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try reject("Explain why the task is blocked.") }
        }
        if let previous {
            let oldIDs = previous.steps.map(\.id)
            let retainedIDs = update.steps.map(\.id).filter { oldIDs.contains($0) }
            let changedScope = previous.steps.contains { old in
                guard let new = update.steps.first(where: { $0.id == old.id }) else { return true }
                return new.title != old.title || (old.status == .completed && new.status != .completed)
            } || retainedIDs != oldIDs.filter { retainedIDs.contains($0) }
            if changedScope && update.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try reject("Explain why the checklist's scope or order changed; do not silently drop unfinished work.") }
        }
        return AITaskPlan(revision: (previous?.revision ?? 0) + 1, steps: update.steps)
    }
}

struct AITaskPlanView: View {
    let plan: AITaskPlan
    var isActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Task plan", systemImage: "checklist").fontWeight(.semibold)
                Spacer()
                Text("\(plan.completedCount) of \(plan.steps.count)").monospacedDigit().foregroundStyle(LimaTheme.textSecondary)
            }
            ForEach(plan.steps) { step in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: symbol(step.status)).frame(width: 15)
                        .foregroundStyle(step.status == .completed ? LimaTheme.success : step.status == .blocked ? LimaTheme.warning : LimaTheme.accentInk)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).strikethrough(step.status == .completed).lineLimit(3)
                        if !step.evidence.isEmpty && step.status == .blocked {
                            Text(step.evidence).foregroundStyle(LimaTheme.textSecondary).font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                    if step.status == .inProgress { Text(isActive ? "Working" : "Unfinished").font(.caption2).foregroundStyle(LimaTheme.textSecondary) }
                }
                .foregroundStyle(step.status == .completed ? LimaTheme.textSecondary : LimaTheme.textPrimary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.title), \(step.status.rawValue), \(step.evidence)")
                .help(step.evidence)
            }
        }
        .limaFont(.caption)
        .padding(12)
        .background(LimaTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: plan)
        .accessibilityIdentifier("ai-task-checklist")
    }
    private func symbol(_ status: AITaskPlanStep.Status) -> String {
        switch status { case .pending: "circle"; case .inProgress: "circle.dotted"; case .completed: "checkmark.circle.fill"; case .blocked: "exclamationmark.circle" }
    }
}
