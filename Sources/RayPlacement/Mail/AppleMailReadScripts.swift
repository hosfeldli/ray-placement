import Foundation

/// Narrow AppleScript source builders and strict descriptor decoding. No user
/// string is inserted into executable syntax without AppleScript quoting.
enum AppleMailReadScripts {
    private static let maximumMailboxes = 500
    private static let maximumCandidates = 500

    private static func literal(_ value: String, maximumBytes: Int) throws -> String {
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw MailCapabilityError.invalidRequest
        }
        return "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func literalList(_ values: [String], maximumBytes: Int) throws -> String {
        let quoted = try values.map { try literal($0, maximumBytes: maximumBytes) }
        return "{" + quoted.joined(separator: ", ") + "}"
    }

    static func mailboxesSource(accountID: String) throws -> String {
        let account = try literal(accountID, maximumBytes: 256)
        return """
        property mailboxRows : {}
        property visitedCount : 0
        tell application id "com.apple.mail"
            set matchingAccounts to (get every account whose id is \(account))
            if (count of matchingAccounts) is not 1 then error number -1728
            set selectedAccount to item 1 of matchingAccounts
            repeat with topBox in (get every mailbox of selectedAccount)
                my collectMailbox(topBox, "", "")
            end repeat
            return mailboxRows
        end tell

        on collectMailbox(theBox, parentID, parentPath)
            tell application id "com.apple.mail"
                set boxName to (name of theBox as text)
                set boxID to parentID & (length of boxName as text) & ":" & boxName
                if parentPath is "" then
                    set displayPath to boxName
                else
                    set displayPath to parentPath & "/" & boxName
                end if
                set visitedCount to visitedCount + 1
                if visitedCount > \(maximumMailboxes) then error number -1728
                set end of mailboxRows to {boxID, boxName, displayPath}
                repeat with childBox in (get every mailbox of theBox)
                    my collectMailbox(childBox, boxID, displayPath)
                end repeat
            end tell
        end collectMailbox
        """
    }

    static func parseMailboxes(_ result: NSAppleEventDescriptor,
                               accountID: String) throws -> [MailMailbox] {
        guard result.numberOfItems <= maximumMailboxes else {
            throw MailCapabilityError.malformedResponse
        }
        var boxes: [MailMailbox] = []
        var seen = Set<String>()
        if result.numberOfItems == 0 { return [] }
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index), row.numberOfItems == 3,
                  let id = row.atIndex(1)?.stringValue,
                  let name = row.atIndex(2)?.stringValue,
                  let path = row.atIndex(3)?.stringValue,
                  !id.isEmpty, id.utf8.count <= 256,
                  !name.isEmpty, name.utf8.count <= 256,
                  !path.isEmpty, path.utf8.count <= 1_024,
                  seen.insert(id).inserted else {
                throw MailCapabilityError.malformedResponse
            }
            boxes.append(MailMailbox(id: id, accountID: accountID,
                                     name: name, path: path))
        }
        return boxes
    }

    private static func searchTerm(_ raw: String) -> (field: String, term: String) {
        guard let colon = raw.firstIndex(of: ":") else { return ("any", raw) }
        let field = raw[..<colon].lowercased()
        guard ["sender", "recipient", "subject", "content"].contains(field) else {
            return ("any", raw)
        }
        let term = String(raw[raw.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? ("any", raw) : (field, term)
    }

    static func searchSource(_ request: MailSearchRequest) throws -> String {
        let accounts = try literalList(request.accountIDs.sorted(), maximumBytes: 256)
        let mailboxes = try literalList(request.mailboxIDs.sorted(), maximumBytes: 256)
        let query = searchTerm(request.query)
        let field = try literal(query.field, maximumBytes: 20)
        let term = try literal(query.term, maximumBytes: 256)
        // AppleScript date literals are locale dependent. Relative seconds use
        // the system clock and a two-second margin; Swift filters exact dates.
        let lowerSeconds = Int(floor(request.receivedAfter.timeIntervalSinceNow)) - 2
        let upperSeconds = Int(ceil(request.receivedBefore.timeIntervalSinceNow)) + 2
        return """
        property resultRows : {}
        property visitedAccounts : {}
        property visitedMailboxes : {}
        property selectedMailboxIDs : \(mailboxes)
        property queryField : \(field)
        property queryText : \(term)
        property scannedCount : 0
        property scanIsPartial : false
        property skippedContent : false
        property lowerBound : missing value
        property upperBound : missing value

        set lowerBound to (current date) + (\(lowerSeconds))
        set upperBound to (current date) + (\(upperSeconds))
        tell application id "com.apple.mail"
            repeat with accountKey in \(accounts)
                if scanIsPartial then exit repeat
                set accountID to (contents of accountKey as text)
                set matchingAccounts to (get every account whose id is accountID)
                if (count of matchingAccounts) is not 1 then error number -1728
                set selectedAccount to item 1 of matchingAccounts
                set end of visitedAccounts to (id of selectedAccount as text)
                repeat with topBox in (get every mailbox of selectedAccount)
                    if scanIsPartial then exit repeat
                    my scanMailbox(topBox, "", accountID)
                end repeat
            end repeat
            return {resultRows, visitedAccounts, visitedMailboxes, scannedCount, scanIsPartial, skippedContent}
        end tell

        on scanMailbox(theBox, parentID, accountID)
            if scanIsPartial then return
            tell application id "com.apple.mail"
                set boxName to (name of theBox as text)
                set boxID to parentID & (length of boxName as text) & ":" & boxName
                if (count of selectedMailboxIDs) is 0 or selectedMailboxIDs contains boxID then
                    set end of visitedMailboxes to boxID
                    set candidates to (get every message of theBox whose date received is greater than or equal to lowerBound and date received is less than or equal to upperBound)
                    repeat with mailItem in candidates
                        if scannedCount >= \(maximumCandidates) or (count of resultRows) >= \(request.limit) then
                            set scanIsPartial to true
                            exit repeat
                        end if
                        set scannedCount to scannedCount + 1
                        set itemSubject to (subject of mailItem as text)
                        set itemSender to (sender of mailItem as text)
                        set itemRecipients to ""
                        if queryField is "any" or queryField is "recipient" then
                            repeat with recipientItem in (get every recipient of mailItem)
                                set itemRecipients to itemRecipients & " " & (address of recipientItem as text)
                            end repeat
                        end if
                        set matched to false
                        if queryText is "" then
                            set matched to true
                        else
                            set searchText to ""
                            if queryField is "any" or queryField is "subject" then set searchText to searchText & " " & itemSubject
                            if queryField is "any" or queryField is "sender" then set searchText to searchText & " " & itemSender
                            if queryField is "any" or queryField is "recipient" then set searchText to searchText & " " & itemRecipients
                            ignoring case
                                if searchText contains queryText then set matched to true
                            end ignoring
                            if not matched and (queryField is "any" or queryField is "content") then
                                try
                                    if (message size of mailItem as integer) <= 131072 then
                                        set bodyText to (content of mailItem as text)
                                        ignoring case
                                            if bodyText contains queryText then set matched to true
                                        end ignoring
                                    else
                                        set skippedContent to true
                                    end if
                                on error
                                    set skippedContent to true
                                end try
                            end if
                        end if
                        if matched then
                            set internetID to ""
                            try
                                set internetID to (message id of mailItem as text)
                            end try
                            set end of resultRows to {accountID, boxID, (id of mailItem as text), internetID, itemSubject, itemSender, (date received of mailItem), (read status of mailItem), (flagged status of mailItem)}
                        end if
                    end repeat
                end if
                if not scanIsPartial then
                    repeat with childBox in (get every mailbox of theBox)
                        if scanIsPartial then exit repeat
                        my scanMailbox(childBox, boxID, accountID)
                    end repeat
                end if
            end tell
        end scanMailbox
        """
    }

    static func parseSearch(_ result: NSAppleEventDescriptor,
                            request: MailSearchRequest) throws -> MailSearchResult {
        guard result.numberOfItems == 6,
              let rowList = result.atIndex(1),
              let accountList = result.atIndex(2),
              let mailboxList = result.atIndex(3),
              let scannedDescriptor = result.atIndex(4),
              let partialDescriptor = result.atIndex(5),
              let skippedDescriptor = result.atIndex(6),
              rowList.numberOfItems <= request.limit,
              accountList.numberOfItems <= request.accountIDs.count,
              mailboxList.numberOfItems <= maximumMailboxes else {
            throw MailCapabilityError.malformedResponse
        }
        let accounts = Set(try strings(in: accountList, maximumBytes: 256))
        let mailboxes = Set(try strings(in: mailboxList, maximumBytes: 256))
        guard accounts.isSubset(of: request.accountIDs),
              request.mailboxIDs.isEmpty || mailboxes.isSubset(of: request.mailboxIDs) else {
            throw MailCapabilityError.providerScopeViolation
        }
        let scanned = Int(scannedDescriptor.int32Value)
        guard (0...maximumCandidates).contains(scanned) else {
            throw MailCapabilityError.malformedResponse
        }
        var messages: [MailMessageSummary] = []
        var skippedRows = false
        if rowList.numberOfItems > 0 {
            for index in 1...rowList.numberOfItems {
                guard let row = rowList.atIndex(index),
                      let summary = parseSummary(row),
                      request.accountIDs.contains(summary.reference.accountID),
                      mailboxes.contains(summary.reference.mailboxID),
                      request.mailboxIDs.isEmpty ||
                          request.mailboxIDs.contains(summary.reference.mailboxID) else {
                    skippedRows = true
                    continue
                }
                let date = summary.reference.receivedAt
                if date >= request.receivedAfter && date <= request.receivedBefore {
                    messages.append(summary)
                }
            }
        }
        let partial = partialDescriptor.booleanValue || skippedDescriptor.booleanValue ||
            skippedRows || accounts != request.accountIDs ||
            (!request.mailboxIDs.isEmpty && mailboxes != request.mailboxIDs)
        let reason = partial ? "Apple Mail search was bounded, incomplete, or a source changed." : nil
        messages.sort { $0.reference.receivedAt > $1.reference.receivedAt }
        return MailSearchResult(
            messages: messages,
            coverage: MailSearchCoverage(accountIDs: accounts, mailboxIDs: mailboxes,
                                         candidateCount: scanned,
                                         isPartial: partial, partialReason: reason)
        )
    }

    private static func strings(in list: NSAppleEventDescriptor,
                                maximumBytes: Int) throws -> [String] {
        if list.numberOfItems == 0 { return [] }
        var values: [String] = []
        for index in 1...list.numberOfItems {
            guard let value = list.atIndex(index)?.stringValue,
                  !value.isEmpty, value.utf8.count <= maximumBytes else {
                throw MailCapabilityError.malformedResponse
            }
            values.append(value)
        }
        guard Set(values).count == values.count else {
            throw MailCapabilityError.malformedResponse
        }
        return values
    }

    private static func parseSummary(_ row: NSAppleEventDescriptor) -> MailMessageSummary? {
        guard row.numberOfItems == 9,
              let accountID = row.atIndex(1)?.stringValue,
              let mailboxID = row.atIndex(2)?.stringValue,
              let numericID = row.atIndex(3)?.stringValue,
              let messageID = Int64(numericID), messageID > 0,
              let internetID = row.atIndex(4)?.stringValue,
              let subject = row.atIndex(5)?.stringValue,
              let sender = row.atIndex(6)?.stringValue,
              let receivedAt = row.atIndex(7)?.dateValue,
              let read = row.atIndex(8),
              let flagged = row.atIndex(9),
              !accountID.isEmpty, accountID.utf8.count <= 256,
              !mailboxID.isEmpty, mailboxID.utf8.count <= 256,
              subject.utf8.count <= 500, sender.utf8.count <= 300,
              internetID.utf8.count <= 512 else {
            return nil
        }
        let reference = MailMessageReference(
            accountID: accountID, mailboxID: mailboxID, messageID: messageID,
            internetMessageID: internetID.isEmpty ? nil : internetID,
            subject: subject, sender: sender,
            receivedAt: receivedAt, capturedAt: Date()
        )
        return MailMessageSummary(reference: reference,
                                  isRead: read.booleanValue,
                                  isFlagged: flagged.booleanValue)
    }

    static func messageSource(_ reference: MailMessageReference) throws -> String {
        let accountID = try literal(reference.accountID, maximumBytes: 256)
        let mailboxID = try literal(reference.mailboxID, maximumBytes: 256)
        guard reference.messageID > 0 else { throw MailCapabilityError.invalidRequest }
        return """
        property locatedMailbox : missing value
        property wantedMailboxID : \(mailboxID)
        tell application id "com.apple.mail"
            set matchingAccounts to (get every account whose id is \(accountID))
            if (count of matchingAccounts) is not 1 then error number -1728
            set selectedAccount to item 1 of matchingAccounts
            repeat with topBox in (get every mailbox of selectedAccount)
                my locateBox(topBox, "")
                if locatedMailbox is not missing value then exit repeat
            end repeat
            if locatedMailbox is missing value then error number -1728
            set matchingMessages to (get every message of locatedMailbox whose id is \(reference.messageID))
            if (count of matchingMessages) is not 1 then error number -1728
            set mailItem to item 1 of matchingMessages
            if (message size of mailItem as integer) > 131072 then return {"too_large"}
            set internetID to ""
            try
                set internetID to (message id of mailItem as text)
            end try
            return {(id of mailItem as text), internetID, (subject of mailItem as text), (sender of mailItem as text), (date received of mailItem), (content of mailItem as text)}
        end tell

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

    static func parseMessage(_ result: NSAppleEventDescriptor,
                             reference: MailMessageReference) throws -> MailMessage {
        if result.numberOfItems == 1,
           result.atIndex(1)?.stringValue == "too_large" {
            throw MailCapabilityError.messageTooLarge
        }
        guard result.numberOfItems == 6,
              let numericID = result.atIndex(1)?.stringValue,
              let messageID = Int64(numericID),
              messageID == reference.messageID,
              let internetID = result.atIndex(2)?.stringValue,
              let subject = result.atIndex(3)?.stringValue,
              let sender = result.atIndex(4)?.stringValue,
              let receivedAt = result.atIndex(5)?.dateValue,
              let body = result.atIndex(6)?.stringValue,
              subject.utf8.count <= 500, sender.utf8.count <= 300,
              internetID.utf8.count <= 512 else {
            throw MailCapabilityError.malformedResponse
        }
        guard body.utf8.count <= 128 * 1_024 else {
            throw MailCapabilityError.messageTooLarge
        }
        let observed = MailMessageReference(
            accountID: reference.accountID, mailboxID: reference.mailboxID,
            messageID: messageID,
            internetMessageID: internetID.isEmpty ? nil : internetID,
            subject: subject, sender: sender,
            receivedAt: receivedAt, capturedAt: Date()
        )
        if let expected = reference.internetMessageID,
           observed.internetMessageID != expected {
            throw MailCapabilityError.providerScopeViolation
        }
        return MailMessage(reference: observed, body: body)
    }
}
