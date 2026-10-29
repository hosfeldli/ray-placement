import Foundation
import Testing
@testable import RayPlacement

@Test func messagesSearchIdentifiersRoundTripWithoutBodies() {
    let chat = "iMessage;-;+15551234567"
    let message = "p:0/ABC-123"
    let chatID = MessagesSearchResultID.chat(chat)
    let messageID = MessagesSearchResultID.message(message, in: chat)
    let replyID = MessagesSearchResultID.reply(to: message, in: chat)

    #expect(MessagesSearchResultID.decode(chatID)?.conversationGUID == chat)
    #expect(MessagesSearchResultID.decode(chatID)?.messageGUID == nil)
    #expect(MessagesSearchResultID.decode(messageID)?.messageGUID == message)
    #expect(MessagesSearchResultID.decode(replyID)?.messageGUID == message)
    #expect(MessagesSearchResultID.isReply(replyID))
    #expect(!MessagesSearchResultID.isReply(messageID))
    #expect(!replyID.contains(message))
    #expect(MessagesSearchResultID.decode("messages:reply:invalid")?.conversationGUID == nil)
}

@Test func messagesPolicyIsClosedByDefault() {
    let policy = MessagesCapabilityPolicy.disabled
    #expect(!policy.readEnabled)
    #expect(!policy.aiReadEnabled)
    #expect(!policy.sendEnabled)
    #expect(!policy.monitorEnabled)
    #expect(!policy.permits("any-chat"))
}

@Test func messagesRequestValidationRejectsUnreviewableDestinationsAndText() throws {
    let valid = MessagesOutgoingRequest(
        destination: .existingConversation(
            guid: "chat-guid", participants: ["+15551234567", "user@example.com"]
        ),
        text: "Hello"
    )
    try valid.validate()

    let empty = MessagesOutgoingRequest(
        destination: .direct(address: "+15551234567", serviceID: "iMessage"),
        text: "   "
    )
    #expect(throws: MessagesCapabilityError.self) { try empty.validate() }

    let duplicateGroup = MessagesOutgoingRequest(
        destination: .existingConversation(
            guid: "chat-guid", participants: ["user@example.com", "USER@example.com"]
        ),
        text: "Hello"
    )
    #expect(throws: MessagesCapabilityError.self) { try duplicateGroup.validate() }
}

@Test func messageContextReferenceRejectsUnboundedSelection() {
    let reference = MessageContextReference(
        kind: .selection, conversationGUID: "chat-guid",
        messageGUID: "message-guid", selectedText: String(repeating: "a", count: 4_097),
        participantLabels: [], messageDate: nil, service: nil, capturedAt: Date()
    )
    #expect(!reference.isValid)
}

@Test func messagesAIToolSchemasAreStrictProviderCompatible() {
    var policy = MessagesCapabilityPolicy.disabled
    policy.readEnabled = true
    policy.aiReadEnabled = true
    policy.sendEnabled = true
    policy.aiComposeEnabled = true
    policy.selectedConversationGUIDs = ["selected-chat"]

    let definitions = AIMessagesTools.definitions(policy: policy)
    #expect(Set(definitions.map(\.id)) == AIMessagesTools.ids)
    #expect(definitions.allSatisfy { $0.responsePayload != nil })
    let requiredSpecActions: Set<String> = [
        "messages_list_chats", "messages_search", "messages_get_messages",
        "messages_get_conversation_summary", "messages_get_participants",
        "messages_list_attachments", "messages_open_conversation",
        "messages_prepare_message", "messages_prepare_reply", "messages_send_reviewed",
        "messages_prepare_attachment", "messages_extract_actions",
        "messages_create_note", "messages_create_reminders",
        "messages_propose_calendar_event", "messages_add_to_context"
    ]
    #expect(requiredSpecActions.isSubset(of: Set(definitions.map(\.id))))
}

@Test func messagesDirectComposeDoesNotRequireHistoryScope() {
    var policy = MessagesCapabilityPolicy.disabled
    policy.sendEnabled = true
    policy.aiComposeEnabled = true
    let definitions = AIMessagesTools.definitions(policy: policy)
    #expect(Set(definitions.map(\.id)) == ["messages_prepare_message"])
    #expect(definitions.allSatisfy { $0.responsePayload != nil })
}

@MainActor
@Test func messagesCrossFeatureWritesAlwaysNeedExactApproval() throws {
    var policy = MessagesCapabilityPolicy.disabled
    policy.readEnabled = true
    policy.aiReadEnabled = true
    policy.selectedConversationGUIDs = ["selected-chat"]
    let definitions = AIMessagesTools.definitions(policy: policy)
    for id in MessagesAIActionTools.exactApprovalIDs {
        let definition = try #require(definitions.first { $0.id == id })
        #expect(AIComputerActionPolicy.shared.requiresApproval(
            for: definition, toolAccessMode: .fullControl
        ))
        #expect(NativeCapabilityAITools.exactApprovalIDs.contains(id))
    }
}

@MainActor
@Test func messageReminderMarkerDeduplicatesTitleButKeepsSourceIdentity() {
    let first = MessageReminderDraft(
        title: "Bring the forms", messageGUID: "message-1",
        evidenceQuote: "Please bring the forms", dueAt: nil
    )
    let sameTask = MessageReminderDraft(
        title: "  BRING   THE  FORMS  ", messageGUID: "message-1",
        evidenceQuote: "Please bring the forms", dueAt: nil
    )
    let anotherMessage = MessageReminderDraft(
        title: "Bring the forms", messageGUID: "message-2",
        evidenceQuote: "Please bring the forms", dueAt: nil
    )
    let marker = EventKitCapabilityService.messageTaskMarker(
        conversationGUID: "chat-1", task: first
    )
    #expect(marker == EventKitCapabilityService.messageTaskMarker(
        conversationGUID: "chat-1", task: sameTask
    ))
    #expect(marker != EventKitCapabilityService.messageTaskMarker(
        conversationGUID: "chat-1", task: anotherMessage
    ))
    #expect(marker != EventKitCapabilityService.messageTaskMarker(
        conversationGUID: "chat-2", task: first
    ))
}
