import Foundation

/// Search IDs carry identifiers, not message bodies. Base64 keeps delimiters
/// unambiguous even when macOS chat GUIDs contain service punctuation.
enum MessagesSearchResultID {
    static func chat(_ guid: String) -> String {
        "messages:chat:\(Data(guid.utf8).base64EncodedString())"
    }

    static func message(_ guid: String, in chatGUID: String) -> String {
        "messages:message:\(Data(chatGUID.utf8).base64EncodedString()):\(Data(guid.utf8).base64EncodedString())"
    }

    static func reply(to guid: String, in chatGUID: String) -> String {
        "messages:reply:\(Data(chatGUID.utf8).base64EncodedString()):\(Data(guid.utf8).base64EncodedString())"
    }

    static func isReply(_ id: String) -> Bool {
        id.hasPrefix("messages:reply:") && decode(id) != nil
    }

    static func decode(_ id: String) -> (conversationGUID: String, messageGUID: String?)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (parts.count == 3 || parts.count == 4), parts[0] == "messages",
              let chatData = Data(base64Encoded: parts[2]),
              let chat = String(data: chatData, encoding: .utf8),
              !chat.isEmpty, chat.utf8.count <= 512 else { return nil }
        if parts[1] == "chat", parts.count == 3 {
            return (chat, nil)
        }
        guard (parts[1] == "message" || parts[1] == "reply"), parts.count == 4,
              let messageData = Data(base64Encoded: parts[3]),
              let message = String(data: messageData, encoding: .utf8),
              !message.isEmpty, message.utf8.count <= 512 else { return nil }
        return (chat, message)
    }
}
