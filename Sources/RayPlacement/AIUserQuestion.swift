import Foundation
import SwiftUI

enum AIUserQuestionKind: String, Codable, Sendable {
    case singleChoice = "single_choice"
    case multipleChoice = "multiple_choice"
    case freeResponse = "free_response"
    case confirmation
}

enum AIUserQuestionPurpose: String, Codable, Sendable {
    case projectResolution = "project_resolution"
    case secureBrowserInput = "secure_browser_input"
}

struct AIUserQuestionOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let detail: String?
}

struct AIUserQuestion: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let kind: AIUserQuestionKind
    /// Optional so questions saved before this field was added still decode.
    let purpose: AIUserQuestionPurpose?
    let title: String?
    let question: String
    let options: [AIUserQuestionOption]
    let allowsOther: Bool
    let placeholder: String?
    let minimumSelections: Int
    let confirmLabel: String?
    let cancelLabel: String?
    let multiline: Bool
    let createdAt: Date
    /// Secure handoff metadata contains no values and is never model-provided copy.
    var browserTabID: UUID? = nil
    var browserPageHost: String? = nil
    var browserDocumentID: String? = nil
    var browserRouteGeneration: UInt64? = nil
    var secureFields: [BrowserSecureFieldStatus]? = nil
}

struct AIUserQuestionResponse: Equatable, Sendable {
    let questionID: UUID
    let selectedOptionIDs: [String]
    let text: String?
    var secureFields: [BrowserSecureFieldStatus]? = nil

    func isValid(for question: AIUserQuestion) -> Bool {
        guard questionID == question.id, selectedOptionIDs.count <= 12,
              Set(selectedOptionIDs).count == selectedOptionIDs.count,
              text.map({ $0.count <= 4_000 }) ?? true else { return false }
        let available = Set(question.options.map(\.id))
        switch question.kind {
        case .singleChoice:
            guard selectedOptionIDs.count == 1 else { return false }
            return available.contains(selectedOptionIDs[0])
                || (question.allowsOther && selectedOptionIDs == ["other"]
                    && !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .multipleChoice:
            guard selectedOptionIDs.count >= question.minimumSelections,
                  selectedOptionIDs.allSatisfy({ available.contains($0) || (question.allowsOther && $0 == "other") })
            else { return false }
            return !selectedOptionIDs.contains("other")
                || !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .freeResponse:
            return selectedOptionIDs.isEmpty
                && !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .confirmation:
            return selectedOptionIDs == ["confirm"] || selectedOptionIDs == ["cancel"]
        }
    }

    var toolPayload: [String: Any] {
        var payload: [String: Any] = [
            "question_id": questionID.uuidString,
            "answered": true,
            "selected_option_ids": selectedOptionIDs,
            "free_response": text as Any? ?? NSNull(),
            "confirmed": selectedOptionIDs == ["confirm"]
        ]
        if let secureFields {
            payload["secure_fields"] = secureFields.map { field in
                ["kind": field.kind, "label": field.label,
                 "required": field.required, "filled": field.filled] as [String: Any]
            }
            payload["values_redacted"] = true
            payload["fresh_browser_read_required"] = true
            payload["final_action_authorized"] = false
        }
        return payload
    }
}

enum AIUserQuestionTools {
    static let ids: Set<String> = ["request_user_input"]
    static let definitions: [LimaAIToolDefinition] = [
        LimaAIToolDefinition(
            id: "request_user_input", name: "request_user_input",
            description: "Pause this same AI run for a structured user answer, then continue with the answer as this tool's output. Ask only when a material decision cannot be inferred from the request, Project, files, or other available context. Supports single_choice, multiple_choice, free_response, and confirmation.",
            parameters: [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ["single_choice", "multiple_choice", "free_response", "confirmation"]],
                    "purpose": ["type": "string", "enum": ["project_resolution", "secure_browser_input"]],
                    "browser_tab_id": ["type": "string"],
                    "title": ["type": "string"],
                    "question": ["type": "string"],
                    "options": ["type": "array", "items": [
                        "type": "object",
                        "properties": ["id": ["type": "string"], "label": ["type": "string"], "detail": ["type": "string"]],
                        "required": ["id", "label"],
                        "additionalProperties": false
                    ]],
                    "allow_other": ["type": "boolean"],
                    "placeholder": ["type": "string"],
                    "minimum_selections": ["type": "integer", "minimum": 1, "maximum": 12],
                    "confirm_label": ["type": "string"],
                    "cancel_label": ["type": "string"],
                    "multiline": ["type": "boolean"]
                ],
                "required": ["kind", "question"],
                "additionalProperties": false
            ],
            risk: .read
        )
    ]

    static func parse(_ raw: String?, runID: UUID) -> AIUserQuestion? {
        guard let raw, raw.utf8.count <= 16_384,
              let data = raw.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kindString = body["kind"] as? String,
              let kind = AIUserQuestionKind(rawValue: kindString),
              let question = body["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.count <= 1_000 else { return nil }
        let allowed: Set<String> = ["kind", "purpose", "title", "question", "options", "allow_other",
                                    "placeholder", "minimum_selections", "confirm_label",
                                    "cancel_label", "multiline", "browser_tab_id"]
        guard Set(body.keys).isSubset(of: allowed) else { return nil }
        func value(_ key: String) -> Any? {
            guard let raw = body[key], !(raw is NSNull) else { return nil }
            return raw
        }
        func shortString(_ key: String, limit: Int = 160) -> String? {
            guard let raw = value(key) as? String, raw.count <= limit else { return nil }
            return raw
        }
        let purpose: AIUserQuestionPurpose?
        if let rawPurpose = value("purpose") {
            guard let value = rawPurpose as? String,
                  let parsed = AIUserQuestionPurpose(rawValue: value) else { return nil }
            purpose = parsed
        } else {
            purpose = nil
        }
        let title = shortString("title")
        let placeholder = shortString("placeholder")
        let confirmLabel = shortString("confirm_label")
        let cancelLabel = shortString("cancel_label")
        if ["title", "placeholder", "confirm_label", "cancel_label"].contains(where: { value($0) != nil && shortString($0) == nil }) {
            return nil
        }
        let allowsOther = value("allow_other") as? Bool ?? false
        let multiline = value("multiline") as? Bool ?? true
        if value("allow_other") != nil && value("allow_other") as? Bool == nil { return nil }
        if value("multiline") != nil && value("multiline") as? Bool == nil { return nil }
        let minimum = value("minimum_selections") as? Int ?? 1
        guard (1...12).contains(minimum) else { return nil }
        if value("minimum_selections") != nil && value("minimum_selections") as? Int == nil { return nil }
        var options: [AIUserQuestionOption] = []
        if let rawOptions = value("options") {
            guard let rawOptions = rawOptions as? [[String: Any]], rawOptions.count <= 12 else { return nil }
            for item in rawOptions {
                guard Set(item.keys).isSubset(of: ["id", "label", "detail"]),
                      let id = item["id"] as? String, !id.isEmpty, id.count <= 64, id != "other",
                      let label = item["label"] as? String, !label.isEmpty, label.count <= 160,
                      item["detail"] == nil || item["detail"] as? String != nil else { return nil }
                let detail = item["detail"] as? String
                guard detail.map({ $0.count <= 240 }) ?? true else { return nil }
                options.append(AIUserQuestionOption(id: id, label: label, detail: detail))
            }
        }
        guard Set(options.map(\.id)).count == options.count else { return nil }
        switch kind {
        case .singleChoice, .multipleChoice:
            guard options.count >= 2, minimum <= options.count + (allowsOther ? 1 : 0) else { return nil }
        case .freeResponse, .confirmation:
            guard options.isEmpty, !allowsOther else { return nil }
        }
        guard purpose != .projectResolution || (kind == .singleChoice
            && options.contains { $0.id == "create_new_project"
                && $0.label.localizedCaseInsensitiveCompare("Create a new project") == .orderedSame }) else {
            return nil
        }
        let browserTabID: UUID?
        if purpose == .secureBrowserInput {
            guard kind == .confirmation, options.isEmpty,
                  let rawTab = value("browser_tab_id") as? String,
                  let parsed = UUID(uuidString: rawTab) else { return nil }
            browserTabID = parsed
        } else {
            guard value("browser_tab_id") == nil else { return nil }
            browserTabID = nil
        }
        var parsedQuestion = AIUserQuestion(
            id: UUID(), runID: runID, kind: kind, purpose: purpose,
            title: title, question: question, options: options, allowsOther: allowsOther,
            placeholder: placeholder, minimumSelections: minimum,
            confirmLabel: confirmLabel, cancelLabel: cancelLabel,
            multiline: multiline, createdAt: Date()
        )
        parsedQuestion.browserTabID = browserTabID
        return parsedQuestion
    }
}

struct AIUserQuestionView: View {
    let question: AIUserQuestion
    let secureInputChecking: Bool
    let secureInputError: String?
    let showBrowserTab: () -> Void
    let answer: (AIUserQuestionResponse) -> Void

    @State private var selected: Set<String> = []
    @State private var otherText = ""
    @State private var responseText = ""

    private var selectedIDs: [String] {
        question.options.map(\.id).filter { selected.contains($0) }
            + (selected.contains("other") ? ["other"] : [])
    }

    private var currentResponse: AIUserQuestionResponse {
        AIUserQuestionResponse(
            questionID: question.id,
            selectedOptionIDs: selectedIDs,
            text: question.kind == .freeResponse ? responseText
                : selected.contains("other") ? otherText : nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if question.purpose == .secureBrowserInput {
                secureBrowserHandoff
            } else {
                Text(question.title ?? "AI needs your input")
                    .font(.headline)
                Text(question.question)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                switch question.kind {
            case .singleChoice, .multipleChoice:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(question.options) { option in
                            Button {
                                if question.kind == .singleChoice {
                                    selected = [option.id]
                                } else if selected.contains(option.id) {
                                    selected.remove(option.id)
                                } else {
                                    selected.insert(option.id)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: selected.contains(option.id)
                                          ? (question.kind == .singleChoice ? "largecircle.fill.circle" : "checkmark.square.fill")
                                          : (question.kind == .singleChoice ? "circle" : "square"))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        if let detail = option.detail {
                                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(CGFloat(question.options.count) * 62, 260))
                if question.allowsOther {
                    Button {
                        if question.kind == .singleChoice {
                            selected = ["other"]
                        } else if selected.contains("other") {
                            selected.remove("other")
                        } else {
                            selected.insert("other")
                        }
                    } label: {
                        Label("Other…", systemImage: selected.contains("other")
                              ? (question.kind == .singleChoice ? "largecircle.fill.circle" : "checkmark.square.fill")
                              : (question.kind == .singleChoice ? "circle" : "square"))
                    }
                    .buttonStyle(.plain)
                    if selected.contains("other") {
                        TextField("Your answer", text: $otherText)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Button("Continue") { answer(currentResponse) }
                    .disabled(!currentResponse.isValid(for: question))
            case .freeResponse:
                if question.multiline {
                    TextEditor(text: $responseText)
                        .frame(minHeight: 72, maxHeight: 150)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                        .overlay(alignment: .topLeading) {
                            if responseText.isEmpty, let placeholder = question.placeholder {
                                Text(placeholder)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 5)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                } else {
                    TextField(question.placeholder ?? "Your answer", text: $responseText)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Answer") { answer(currentResponse) }
                    .disabled(!currentResponse.isValid(for: question))
            case .confirmation:
                HStack {
                    Button(question.cancelLabel ?? "Keep existing version") {
                        answer(AIUserQuestionResponse(questionID: question.id,
                            selectedOptionIDs: ["cancel"], text: nil))
                    }
                    Button(question.confirmLabel ?? "Confirm") {
                        answer(AIUserQuestionResponse(questionID: question.id,
                            selectedOptionIDs: ["confirm"], text: nil))
                    }
                }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("ai-user-question")
    }

    private var secureBrowserHandoff: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Secure information needed", systemImage: "lock.shield")
                .font(.headline)
            if let host = question.browserPageHost {
                Text(host).font(.caption).foregroundStyle(.secondary)
            }
            Text("Enter payment or sign-in details directly on the website in Lima’s Browser. Lima does not receive the field values. Verify the site before entering them.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array((question.secureFields ?? []).enumerated()), id: \.offset) { _, field in
                Label(field.label, systemImage: "lock.fill")
                    .font(.caption)
            }
            Text("Continuing will refresh the page state for review. It will not authorize a purchase, booking, or other final action.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let secureInputError {
                Text(secureInputError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("ai-secure-input-error")
            }
            HStack {
                Button("Show website") { showBrowserTab() }
                Button("Cancel") {
                    answer(AIUserQuestionResponse(questionID: question.id,
                        selectedOptionIDs: ["cancel"], text: nil))
                }
                Spacer()
                Button(secureInputChecking ? "Checking…" : "I’ve entered the details") {
                    answer(AIUserQuestionResponse(questionID: question.id,
                        selectedOptionIDs: ["confirm"], text: nil))
                }
                .disabled(secureInputChecking)
                .keyboardShortcut(.defaultAction)
            }
        }
        .accessibilityIdentifier("ai-secure-browser-handoff")
    }
}
