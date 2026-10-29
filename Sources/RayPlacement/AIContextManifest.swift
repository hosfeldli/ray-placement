import Foundation

enum AIContextDelivery: String, Codable, Sendable {
    case attachedWithMessage
    case includedInInstructions
    case availableThroughTool
    case priorConversation

    var title: String {
        switch self {
        case .attachedWithMessage: return "Attached with message"
        case .includedInInstructions: return "Included in instructions"
        case .availableThroughTool: return "Tool access only"
        case .priorConversation: return "Prior conversation"
        }
    }
}

enum AIContextAvailability: String, Codable, Sendable {
    case ready
    case changed
    case unavailable
}

struct AIContextEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let delivery: AIContextDelivery
    let availability: AIContextAvailability
}

struct AIContextPermissionsSnapshot: Codable, Hashable, Sendable {
    let toolAccessMode: String
    let routedToolIDs: [String]
    let browserControlMode: String
}

/// Metadata only: no prompt, attachment body, file path, or webpage contents.
/// Frozen at Send from the same attachment list and routed tool set used by the run.
struct AIContextManifest: Codable, Hashable, Sendable {
    let conversationID: UUID
    let userMessageID: UUID
    let entries: [AIContextEntry]
    let permissionsSnapshot: AIContextPermissionsSnapshot
    let createdAt: Date

    init(
        conversationID: UUID,
        userMessageID: UUID,
        attachments: [AIAttachment],
        instructionSources: [String],
        browserTabTitle: String?,
        browserTabHost: String?,
        browserToolRouted: Bool,
        hasPriorConversation: Bool,
        permissionsSnapshot: AIContextPermissionsSnapshot,
        selectedShelfMailCount: Int = 0,
        selectedShelfMessageCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.permissionsSnapshot = permissionsSnapshot
        self.createdAt = createdAt
        var entries = attachments.map(Self.attachmentEntry)
        entries += instructionSources.enumerated().map { index, title in
            AIContextEntry(
                id: "instruction-\(index)",
                title: title,
                detail: "Included in this request's system instructions.",
                delivery: .includedInInstructions,
                availability: .ready
            )
        }
        if let browserTabTitle {
            let host = browserTabHost.map { " · \($0)" } ?? ""
            entries.append(AIContextEntry(
                id: "browser-tab",
                title: browserTabTitle + host,
                detail: browserToolRouted
                    ? "Page contents are not attached. A routed Browser tool may read this tab only when Browser AI Control and action policy allow it."
                    : "Page contents are not attached. No Browser read tool is routed for this request.",
                delivery: .availableThroughTool,
                availability: browserToolRouted ? .ready : .unavailable
            ))
        }
        if selectedShelfMailCount > 0 {
            let routed = permissionsSnapshot.routedToolIDs.contains("mail_context")
            entries.append(AIContextEntry(
                id: "selected-shelf-mail",
                title: "\(selectedShelfMailCount) selected Mail reference\(selectedShelfMailCount == 1 ? "" : "s")",
                detail: routed
                    ? "Message bodies are not attached. An authorized Mail tool can resolve each reference and detect a changed or missing source."
                    : "Message bodies are not attached. The scoped Mail resolver is not routed for this request.",
                delivery: .availableThroughTool,
                availability: routed ? .ready : .unavailable
            ))
        }
        if selectedShelfMessageCount > 0 {
            let routed = permissionsSnapshot.routedToolIDs.contains("messages_context")
            entries.append(AIContextEntry(
                id: "selected-shelf-messages",
                title: "\(selectedShelfMessageCount) selected Messages reference\(selectedShelfMessageCount == 1 ? "" : "s")",
                detail: routed
                    ? "Conversation histories are not attached. An authorized Messages tool can re-read each selected source within the current scope."
                    : "Conversation histories are not attached. The scoped Messages resolver is not routed for this request.",
                delivery: .availableThroughTool,
                availability: routed ? .ready : .unavailable
            ))
        }
        if hasPriorConversation {
            entries.append(AIContextEntry(
                id: "prior-conversation",
                title: "Prior chat",
                detail: "The provider may receive bounded prior conversation context or a continuation reference.",
                delivery: .priorConversation,
                availability: .ready
            ))
        }
        self.entries = entries
    }

    static func attachmentEntry(_ attachment: AIAttachment) -> AIContextEntry {
        let availability: AIContextAvailability
        switch attachment.kind {
        case .clipboard, .selection:
            availability = attachment.text?.isEmpty == false ? .ready : .unavailable
        case .pastedText, .file, .image:
            if !AIFileAttachmentPolicy.canAttach(attachment) {
                availability = .unavailable
            } else if let path = attachment.path,
                      let values = try? URL(fileURLWithPath: path)
                        .resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      modified.timeIntervalSince(attachment.createdAt) > 1 {
                availability = .changed
            } else {
                availability = .ready
            }
        }
        let detail: String
        switch availability {
        case .ready:
            detail = attachment.metadataSummary ?? "Selected content is prepared with this message."
        case .changed:
            detail = "This file changed after it was selected; review it before sending."
        case .unavailable:
            detail = "This item is unavailable or exceeds Lima's attachment policy."
        }
        return AIContextEntry(
            id: "attachment-\(attachment.id.uuidString)",
            title: attachment.displayName,
            detail: detail,
            delivery: .attachedWithMessage,
            availability: availability
        )
    }
}
