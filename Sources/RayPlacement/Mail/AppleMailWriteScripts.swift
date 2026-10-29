import AppKit
import Foundation

/// AppleScript source for user-initiated Mail writes. Every interpolated value
/// is emitted as a quoted value or text expression; references are resolved
/// inside the selected account and mailbox immediately before use.
enum AppleMailWriteScripts {
    private static func literal(_ value: String, maximumBytes: Int,
                                allowEmpty: Bool = false) throws -> String {
        guard (allowEmpty || !value.isEmpty), value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw MailCapabilityError.invalidRequest
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func bodyExpression(_ value: String) throws -> String {
        guard value.utf8.count <= 128 * 1_024,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) &&
                      $0.value != 9 && $0.value != 10 && $0.value != 13
              }) else {
            throw MailCapabilityError.invalidOutgoingMessage
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\" & (ASCII character 9) & \"")
            .replacingOccurrences(of: "\r", with: "\" & (ASCII character 13) & \"")
            .replacingOccurrences(of: "\n", with: "\" & (ASCII character 10) & \"")
        return "\"" + escaped + "\""
    }

    private static func addressList(_ addresses: [String]) throws -> String {
        let values = try addresses.map {
            guard MailOutgoingRequest.isAddress($0) else {
                throw MailCapabilityError.invalidOutgoingMessage
            }
            return try literal($0, maximumBytes: 320)
        }
        return "{" + values.joined(separator: ", ") + "}"
    }

    private static func attachmentPaths(_ attachments: [MailOutgoingAttachment]) throws -> String {
        let values = try attachments.map {
            try literal($0.path, maximumBytes: 2_048)
        }
        return "{" + values.joined(separator: ", ") + "}"
    }

    static func sendingIdentitiesSource(accountID: String) throws -> String {
        let account = try literal(accountID, maximumBytes: 256)
        return """
        tell application id "com.apple.mail"
            set matchingAccounts to (get every account whose id is \(account))
            if (count of matchingAccounts) is not 1 then error number -1728
            set selectedAccount to item 1 of matchingAccounts
            set selectedAddresses to (email addresses of selectedAccount)
            set availableAddresses to {}
            repeat with candidateAddress in selectedAddresses
                set candidateText to (contents of candidateAddress as text)
                set isAmbiguous to false
                repeat with otherAccount in (get every account)
                    if (id of otherAccount as text) is not \(account) then
                        if candidateText is in (email addresses of otherAccount) then
                            set isAmbiguous to true
                            exit repeat
                        end if
                    end if
                end repeat
                if not isAmbiguous then set end of availableAddresses to candidateText
            end repeat
            return availableAddresses
        end tell
        """
    }

    static func parseSendingIdentities(_ result: NSAppleEventDescriptor) throws -> [String] {
        guard result.numberOfItems > 0, result.numberOfItems <= 20 else {
            throw MailCapabilityError.malformedResponse
        }
        var addresses: [String] = []
        for index in 1...result.numberOfItems {
            guard let address = result.atIndex(index)?.stringValue,
                  MailOutgoingRequest.isAddress(address) else {
                throw MailCapabilityError.malformedResponse
            }
            addresses.append(address)
        }
        guard Set(addresses.map { $0.lowercased() }).count == addresses.count else {
            throw MailCapabilityError.malformedResponse
        }
        return addresses
    }

    static func replyTargetSource(_ reference: MailMessageReference) throws -> String {
        let lookup = try sourceLookup(reference)
        return """
        property locatedMailbox : missing value
        property wantedMailboxID : \(try literal(reference.mailboxID, maximumBytes: 256))
        tell application id "com.apple.mail"
        \(lookup)
            set addressText to ""
            try
                set addressText to (reply to of mailItem as text)
            end try
            if addressText is "" then set addressText to (sender of mailItem as text)
            set targetAddress to (extract address from addressText)
            set internetID to ""
            try
                set internetID to (message id of mailItem as text)
            end try
            return {(id of mailItem as text), internetID, (subject of mailItem as text), (sender of mailItem as text), (date received of mailItem), targetAddress}
        end tell
        \(locatorHandler)
        """
    }

    static func parseReplyTarget(_ result: NSAppleEventDescriptor,
                                 reference: MailMessageReference) throws -> MailReplyTarget {
        guard result.numberOfItems == 6,
              let numericID = result.atIndex(1)?.stringValue,
              Int64(numericID) == reference.messageID,
              let internetID = result.atIndex(2)?.stringValue,
              let subject = result.atIndex(3)?.stringValue,
              let sender = result.atIndex(4)?.stringValue,
              let receivedAt = result.atIndex(5)?.dateValue,
              let address = result.atIndex(6)?.stringValue,
              subject == reference.subject,
              sender == reference.sender,
              receivedAt == reference.receivedAt,
              (reference.internetMessageID == nil ||
               internetID == reference.internetMessageID),
              MailOutgoingRequest.isAddress(address) else {
            throw MailCapabilityError.providerScopeViolation
        }
        return MailReplyTarget(reference: reference, recipientAddress: address)
    }

    static func openSource(_ reference: MailMessageReference) throws -> String {
        let lookup = try sourceLookup(reference)
        let check = try sourceCheck(reference)
        return """
        property locatedMailbox : missing value
        property wantedMailboxID : \(try literal(reference.mailboxID, maximumBytes: 256))
        tell application id "com.apple.mail"
        \(lookup)
        \(check)
            open mailItem
            return "opened"
        end tell
        \(locatorHandler)
        """
    }

    static func messageActionSource(_ request: MailMessageActionRequest) throws -> String {
        try request.validate()
        let reference = request.reference
        let lookup = try sourceLookup(reference)
        let check = try sourceCheck(reference)
        let command: String
        switch request.kind {
        case .move(let destination), .archive(let destination):
            let targetID = try literal(destination.id, maximumBytes: 256)
            command = """
                set locatedMailbox to missing value
                set wantedMailboxID to \(targetID)
                repeat with topBox in (get every mailbox of sourceAccount)
                    my locateBox(topBox, "")
                    if locatedMailbox is not missing value then exit repeat
                end repeat
                if locatedMailbox is missing value then error number -1728
                set destinationMailbox to locatedMailbox
                move mailItem to destinationMailbox
                return "moved"
            """
        case .delete:
            command = """
                delete mailItem
                return "deleted"
            """
        }
        return """
        property locatedMailbox : missing value
        property wantedMailboxID : \(try literal(reference.mailboxID, maximumBytes: 256))
        tell application id "com.apple.mail"
        \(lookup)
        \(check)
        \(command)
        end tell
        \(locatorHandler)
        """
    }

    static func outgoingSource(_ request: MailOutgoingRequest,
                               saveOnly: Bool) throws -> String {
        try request.validate(allowIncompleteDraft: saveOnly)
        let account = try literal(request.accountID, maximumBytes: 256)
        let sender = try literal(request.senderAddress, maximumBytes: 320)
        let subject = try literal(request.subject, maximumBytes: 500,
                                  allowEmpty: saveOnly)
        let body = try bodyExpression(request.body)
        let to = try addressList(request.to)
        let cc = try addressList(request.cc)
        let bcc = try addressList(request.bcc)
        let paths = try attachmentPaths(request.attachments)

        let sourcePrelude: String
        let composeCommand: String
        let handler: String
        switch request.kind {
        case .newMessage:
            sourcePrelude = ""
            composeCommand = "set outgoingItem to (make new outgoing message with properties {visible:false})"
            handler = ""
        case .reply(let reference):
            sourcePrelude = try sourceLookup(reference) + "\n" + sourceCheck(reference)
            composeCommand = "set outgoingItem to (reply mailItem opening window false reply to all false)"
            handler = locatorHandler
        case .forward(let reference):
            sourcePrelude = try sourceLookup(reference) + "\n" + sourceCheck(reference)
            composeCommand = "set outgoingItem to (forward mailItem opening window false)"
            handler = locatorHandler
        }

        let referenceProperties: String
        switch request.kind {
        case .newMessage:
            referenceProperties = ""
        case .reply(let reference), .forward(let reference):
            referenceProperties = """
            property locatedMailbox : missing value
            property wantedMailboxID : \(try literal(reference.mailboxID, maximumBytes: 256))
            """
        }

        let finish: String = saveOnly
            ? """
                save outgoingItem
                return "saved"
              """
            : """
                set acceptedByMail to (send outgoingItem)
                if acceptedByMail is true then return "accepted"
                return "uncertain"
              """

        return """
        \(referenceProperties)
        tell application id "com.apple.mail"
            set matchingAccounts to (get every account whose id is \(account))
            if (count of matchingAccounts) is not 1 then error number -1728
            set selectedAccount to item 1 of matchingAccounts
            set requestedSender to \(sender)
            if requestedSender is not in (email addresses of selectedAccount) then error number -1728
            repeat with otherAccount in (get every account)
                if (id of otherAccount as text) is not \(account) then
                    if requestedSender is in (email addresses of otherAccount) then error number -1728
                end if
            end repeat
        \(sourcePrelude)
            \(composeCommand)
            set visible of outgoingItem to false
            set sender of outgoingItem to requestedSender
            set subject of outgoingItem to \(subject)
            try
                set message signature of outgoingItem to missing value
            end try
            set outgoingBody to \(body)
            set content of outgoingItem to outgoingBody
            repeat while (count of to recipients of outgoingItem) > 0
                delete item 1 of to recipients of outgoingItem
            end repeat
            repeat while (count of cc recipients of outgoingItem) > 0
                delete item 1 of cc recipients of outgoingItem
            end repeat
            repeat while (count of bcc recipients of outgoingItem) > 0
                delete item 1 of bcc recipients of outgoingItem
            end repeat
            set requestedTo to \(to)
            set requestedCc to \(cc)
            set requestedBcc to \(bcc)
            repeat with addressValue in requestedTo
                make new to recipient at end of to recipients of outgoingItem with properties {address:(contents of addressValue)}
            end repeat
            repeat with addressValue in requestedCc
                make new cc recipient at end of cc recipients of outgoingItem with properties {address:(contents of addressValue)}
            end repeat
            repeat with addressValue in requestedBcc
                make new bcc recipient at end of bcc recipients of outgoingItem with properties {address:(contents of addressValue)}
            end repeat
            if (extract address from (sender of outgoingItem as text)) is not requestedSender then error number -1728
            considering case
                if (subject of outgoingItem as text) is not \(subject) then error number -1728
                -- Mail can append exactly one space to an unsent message body.
                -- Accept only that observed normalization, not other body changes.
                set actualBody to (content of outgoingItem as text)
                if actualBody is not outgoingBody and actualBody is not (outgoingBody & " ") then error number -1728
            end considering
            if (address of every to recipient of outgoingItem) is not requestedTo then error number -1728
            if (address of every cc recipient of outgoingItem) is not requestedCc then error number -1728
            if (address of every bcc recipient of outgoingItem) is not requestedBcc then error number -1728
            if (count of attachments of content of outgoingItem) is not 0 then error number -1728
            set requestedAttachments to \(paths)
            repeat with attachmentPath in requestedAttachments
                tell content of outgoingItem
                    make new attachment with properties {file name:(POSIX file (contents of attachmentPath))} at after the last paragraph
                end tell
            end repeat
            if (count of attachments of content of outgoingItem) is not (count of requestedAttachments) then error number -1728
            \(finish)
        end tell
        \(handler)
        """
    }

    static func parseSend(_ result: NSAppleEventDescriptor) throws -> MailSendReceipt {
        guard let status = result.stringValue else {
            throw MailCapabilityError.malformedResponse
        }
        switch status {
        case "accepted":
            return MailSendReceipt(acceptedAt: Date(), providerMessageID: nil)
        case "uncertain":
            throw MailCapabilityError.sendOutcomeUncertain
        default:
            throw MailCapabilityError.malformedResponse
        }
    }

    static func parseDraft(_ result: NSAppleEventDescriptor) throws -> MailDraftReceipt {
        guard result.stringValue == "saved" else {
            throw MailCapabilityError.malformedResponse
        }
        return MailDraftReceipt(savedAt: Date())
    }

    static func parseOpen(_ result: NSAppleEventDescriptor) throws {
        guard result.stringValue == "opened" else {
            throw MailCapabilityError.malformedResponse
        }
    }

    static func parseMessageAction(_ result: NSAppleEventDescriptor,
                                   kind: MailMessageActionKind) throws {
        let expected: String
        switch kind {
        case .move, .archive: expected = "moved"
        case .delete: expected = "deleted"
        }
        guard result.stringValue == expected else {
            throw MailCapabilityError.malformedResponse
        }
    }

    private static func sourceLookup(_ reference: MailMessageReference) throws -> String {
        guard reference.messageID > 0 else { throw MailCapabilityError.invalidRequest }
        let account = try literal(reference.accountID, maximumBytes: 256)
        return """
            set matchingSourceAccounts to (get every account whose id is \(account))
            if (count of matchingSourceAccounts) is not 1 then error number -1728
            set sourceAccount to item 1 of matchingSourceAccounts
            repeat with topBox in (get every mailbox of sourceAccount)
                my locateBox(topBox, "")
                if locatedMailbox is not missing value then exit repeat
            end repeat
            if locatedMailbox is missing value then error number -1728
            set matchingMessages to (get every message of locatedMailbox whose id is \(reference.messageID))
            if (count of matchingMessages) is not 1 then error number -1728
            set mailItem to item 1 of matchingMessages
        """
    }

    private static func sourceCheck(_ reference: MailMessageReference) throws -> String {
        let subject = try literal(reference.subject, maximumBytes: 500, allowEmpty: true)
        let sender = try literal(reference.sender, maximumBytes: 300)
        let internetID = try literal(reference.internetMessageID ?? "", maximumBytes: 512,
                                     allowEmpty: true)
        return """
            considering case
                if (subject of mailItem as text) is not \(subject) then error number -1728
                if (sender of mailItem as text) is not \(sender) then error number -1728
                if \(internetID) is not "" then
                    set observedInternetID to ""
                    try
                        set observedInternetID to (message id of mailItem as text)
                    end try
                    if observedInternetID is not \(internetID) then error number -1728
                end if
            end considering
        """
    }

    private static let locatorHandler = """
    on locateBox(theBox, parentID)
        if locatedMailbox is not missing value then return
        tell application id "com.apple.mail"
            set boxName to (name of theBox as text)
            set boxID to parentID & (length of boxName as text) & ":" & boxName
            if boxID is wantedMailboxID then
                set locatedMailbox to theBox
                return
            end if
            repeat with childBox in (get every mailbox of theBox)
                my locateBox(childBox, boxID)
                if locatedMailbox is not missing value then exit repeat
            end repeat
        end tell
    end locateBox
    """
}
