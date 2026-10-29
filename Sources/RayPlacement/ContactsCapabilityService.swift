import Contacts
import CryptoKit
import Foundation
import RayPlacementCore

/// Contacts are resolved live from macOS after Lima's one-use exact-call review.
/// Lima does not persist an address book or silently choose among duplicate names.
@MainActor
final class ContactsCapabilityService {
    static let shared = ContactsCapabilityService()
    static let supportedOperations: Set<NativeCapabilityOperation> = [
        .contactsSearch, .contactsGet, .contactsFindEmail, .contactsFindPhone,
        .contactsCreate, .contactsUpdate
    ]

    enum Failure: LocalizedError {
        case invalidArguments
        case permissionDenied
        case notFound
        case stale
        case ambiguous
        case duplicate
        case noChange

        var errorDescription: String? {
            switch self {
            case .invalidArguments: return "The Contacts request needs bounded, exact fields from a recent Contacts lookup."
            case .permissionDenied: return "macOS Contacts access is not granted for Lima. Enable it in System Settings and retry."
            case .notFound: return "That contact is no longer available."
            case .stale: return "The contact changed since it was read. Fetch it again before updating."
            case .ambiguous: return "More than one matching address or number exists. Fetch the contact and choose an exact value."
            case .duplicate: return "A contact or contact method already matches this proposal. Review the existing result instead."
            case .noChange: return "The proposed Contacts update would not change anything."
            }
        }
    }

    private let permissionStore = CNContactStore()
    private init() {}

    func execute(_ operation: NativeCapabilityOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard Self.supportedOperations.contains(operation) else { throw Failure.invalidArguments }
        try await ensureAccess()
        return try await Task.detached(priority: .utility) {
            try Self.perform(operation, arguments: arguments)
        }.value
    }

    private func ensureAccess() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                permissionStore.requestAccess(for: .contacts) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted, CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                throw Failure.permissionDenied
            }
        default:
            throw Failure.permissionDenied
        }
    }

    nonisolated private static func perform(
        _ operation: NativeCapabilityOperation, arguments: [String: JSONValue]
    ) throws -> JSONValue {
        let store = CNContactStore()
        switch operation {
        case .contactsSearch:
            try requireKeys(arguments, ["query"])
            let query = try requiredText(arguments, "query", maximum: 160)
            let request = CNContactFetchRequest(keysToFetch: contactKeys)
            request.predicate = CNContact.predicateForContacts(matchingName: query)
            request.unifyResults = true
            var matches: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, stop in
                matches.append(contact)
                if matches.count > 20 { stop.pointee = true }
            }
            return listResult(matches, limit: 20)
        case .contactsGet:
            try requireKeys(arguments, ["contact_id"])
            let id = try requiredText(arguments, "contact_id", maximum: 300)
            return .object(["contact": contactJSON(try existingContact(id, store: store))])
        case .contactsFindEmail:
            try requireKeys(arguments, ["email"])
            let email = try requiredEmail(arguments, "email")
            let matches = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingEmailAddress: email),
                keysToFetch: contactKeys
            ).filter { contact in
                contact.emailAddresses.contains {
                    ($0.value as String).caseInsensitiveCompare(email) == .orderedSame
                }
            }
            return listResult(matches, limit: 20)
        case .contactsFindPhone:
            try requireKeys(arguments, ["phone"])
            let query = digits(try requiredText(arguments, "phone", maximum: 40))
            guard (4...20).contains(query.count) else { throw Failure.invalidArguments }
            let request = CNContactFetchRequest(keysToFetch: contactKeys)
            request.unifyResults = true
            var matches: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, stop in
                if contact.phoneNumbers.contains(where: {
                    let candidate = digits($0.value.stringValue)
                    return candidate == query || candidate.hasSuffix(query)
                }) {
                    matches.append(contact)
                    if matches.count > 20 { stop.pointee = true }
                }
            }
            return listResult(matches, limit: 20)
        case .contactsCreate:
            try requireKeys(arguments, ["given_name", "family_name", "organization", "emails", "phones"])
            let given = try optionalName(arguments, "given_name")
            let family = try optionalName(arguments, "family_name")
            let organization = try optionalName(arguments, "organization")
            let emails = try stringArray(arguments, "emails", maximumCount: 5, maximumLength: 254)
            let phones = try stringArray(arguments, "phones", maximumCount: 5, maximumLength: 40)
            guard ![given, family, organization].allSatisfy(\.isEmpty),
                  !emails.isEmpty || !phones.isEmpty,
                  emails.allSatisfy(validEmail),
                  phones.allSatisfy({ (7...20).contains(digits($0).count) }),
                  Set(emails.map { $0.lowercased() }).count == emails.count,
                  Set(phones.map(digits)).count == phones.count else {
                throw Failure.invalidArguments
            }
            for email in emails {
                let existing = try store.unifiedContacts(
                    matching: CNContact.predicateForContacts(matchingEmailAddress: email),
                    keysToFetch: contactKeys
                )
                guard !existing.contains(where: { contact in
                    contact.emailAddresses.contains {
                        ($0.value as String).caseInsensitiveCompare(email) == .orderedSame
                    }
                }) else { throw Failure.duplicate }
            }
            let contact = CNMutableContact()
            contact.givenName = given
            contact.familyName = family
            contact.organizationName = organization
            contact.emailAddresses = emails.map {
                CNLabeledValue(label: CNLabelWork, value: $0 as NSString)
            }
            contact.phoneNumbers = phones.map {
                CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: $0))
            }
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            try store.execute(request)
            // The save is committed. A failed readback must not make the AI
            // believe creation failed and propose a duplicate second write.
            let saved = try? existingContact(contact.identifier, store: store)
            return .object(["completed": .bool(true), "result": .string("created"),
                            "contact_id": .string(saved?.identifier ?? contact.identifier),
                            "contact": saved.map(contactJSON) ?? .null,
                            "readback_completed": .bool(saved != nil),
                            "retry_safe": .bool(false),
                            "next_action": .string(saved == nil ? "contacts_search" : "contacts_get")])
        case .contactsUpdate:
            try requireKeys(arguments, ["contact_id", "expected_fingerprint", "field", "old_value", "new_value"])
            let id = try requiredText(arguments, "contact_id", maximum: 300)
            let expected = try requiredText(arguments, "expected_fingerprint", maximum: 64)
            guard expected.count == 64,
                  expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidArguments
            }
            let contact = try existingContact(id, store: store)
            guard fingerprint(contact) == expected else { throw Failure.stale }
            let field = try requiredText(arguments, "field", maximum: 30)
            let oldValue = try requiredOptionalString(arguments, "old_value", maximum: 254)
            let newValue = try requiredTextAllowEmpty(arguments, "new_value", maximum: 254)
            guard let mutable = contact.mutableCopy() as? CNMutableContact else {
                throw Failure.notFound
            }
            try applyUpdate(field: field, oldValue: oldValue, newValue: newValue, to: mutable)
            if field == "email", !newValue.isEmpty {
                let matches = try store.unifiedContacts(
                    matching: CNContact.predicateForContacts(matchingEmailAddress: newValue),
                    keysToFetch: contactKeys
                )
                guard !matches.contains(where: { contact in
                    contact.identifier != id && contact.emailAddresses.contains {
                        ($0.value as String).caseInsensitiveCompare(newValue) == .orderedSame
                    }
                }) else { throw Failure.duplicate }
            }
            guard fingerprint(mutable) != expected else { throw Failure.noChange }
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
            // Report the committed update even if macOS cannot immediately
            // return the unified contact after the save.
            let saved = try? existingContact(id, store: store)
            return .object(["completed": .bool(true), "result": .string("updated"),
                            "contact_id": .string(id),
                            "contact": saved.map(contactJSON) ?? .null,
                            "readback_completed": .bool(saved != nil),
                            "retry_safe": .bool(false),
                            "next_action": .string("contacts_get")])
        default:
            throw Failure.invalidArguments
        }
    }

    nonisolated private static var contactKeys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
    }

    nonisolated private static func existingContact(_ id: String, store: CNContactStore) throws -> CNContact {
        let matches = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(withIdentifiers: [id]),
            keysToFetch: contactKeys
        )
        guard matches.count == 1, let contact = matches.first else { throw Failure.notFound }
        return contact
    }

    nonisolated private static func listResult(_ contacts: [CNContact], limit: Int) -> JSONValue {
        let singleContact = contacts.count == 1 ? contacts.first : nil
        let resolvedEmail = singleContact.flatMap(recipientEmail)
        let resolution = contacts.isEmpty ? "not_found"
            : contacts.count > 1 ? "multiple_contacts"
            : singleContact.map(recipientResolution) ?? "not_found"
        return .object([
            "contacts": .array(Array(contacts.prefix(limit)).map(contactJSON)),
            "matches_observed": .number(Double(contacts.count)),
            "truncated": .bool(contacts.count > limit),
            "ambiguous": .bool(contacts.count > 1),
            "recipient_resolution": .string(resolution),
            "recipient_email": resolvedEmail.map(JSONValue.string) ?? .null
        ])
    }

    nonisolated private static func recipientEmail(_ contact: CNContact) -> String? {
        let addresses = contact.emailAddresses.map { $0.value as String }
        guard let first = addresses.first, validEmail(first),
              Set(addresses.map { $0.lowercased() }).count == 1,
              addresses.allSatisfy(validEmail) else { return nil }
        return first
    }

    nonisolated private static func recipientResolution(_ contact: CNContact) -> String {
        if contact.emailAddresses.isEmpty { return "no_email" }
        return recipientEmail(contact) == nil ? "multiple_or_invalid_emails" : "resolved"
    }

    nonisolated private static func contactJSON(_ contact: CNContact) -> JSONValue {
        let fullName = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let displayName = !fullName.isEmpty ? fullName
            : !contact.organizationName.isEmpty ? contact.organizationName : "Unnamed contact"
        return .object([
            "contact_id": .string(contact.identifier),
            "display_name": .string(displayName),
            "given_name": .string(contact.givenName),
            "family_name": .string(contact.familyName),
            "organization": .string(contact.organizationName),
            "emails": .array(contact.emailAddresses.map {
                .object(["label": .string($0.label ?? ""),
                         "value": .string($0.value as String)])
            }),
            "phones": .array(contact.phoneNumbers.map {
                .object(["label": .string($0.label ?? ""),
                         "value": .string($0.value.stringValue)])
            }),
            "recipient_resolution": .string(recipientResolution(contact)),
            "recipient_email": recipientEmail(contact).map(JSONValue.string) ?? .null,
            "fingerprint": .string(fingerprint(contact))
        ])
    }

    nonisolated private static func fingerprint(_ contact: CNContact) -> String {
        let parts = [
            contact.identifier, contact.givenName, contact.familyName,
            contact.organizationName
        ] + contact.emailAddresses.flatMap {
            [$0.label ?? "", $0.value as String]
        } + contact.phoneNumbers.flatMap {
            [$0.label ?? "", $0.value.stringValue]
        }
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func applyUpdate(
        field: String, oldValue: String?, newValue: String, to contact: CNMutableContact
    ) throws {
        switch field {
        case "given_name", "family_name", "organization":
            guard newValue.count <= 120, oldValue != nil else { throw Failure.invalidArguments }
            let current: String
            switch field {
            case "given_name": current = contact.givenName
            case "family_name": current = contact.familyName
            default: current = contact.organizationName
            }
            guard current == oldValue else { throw Failure.stale }
            switch field {
            case "given_name": contact.givenName = newValue
            case "family_name": contact.familyName = newValue
            default: contact.organizationName = newValue
            }
            guard ![contact.givenName, contact.familyName, contact.organizationName]
                .allSatisfy(\.isEmpty) else { throw Failure.invalidArguments }
        case "email":
            guard newValue.isEmpty || validEmail(newValue) else { throw Failure.invalidArguments }
            var values = contact.emailAddresses
            if let oldValue {
                let matches = values.indices.filter {
                    (values[$0].value as String).caseInsensitiveCompare(oldValue) == .orderedSame
                }
                guard matches.count == 1, let index = matches.first else { throw Failure.ambiguous }
                if newValue.isEmpty {
                    values.remove(at: index)
                } else {
                    guard !values.contains(where: {
                        ($0.value as String).caseInsensitiveCompare(newValue) == .orderedSame
                            && ($0.value as String).caseInsensitiveCompare(oldValue) != .orderedSame
                    }) else { throw Failure.duplicate }
                    values[index] = CNLabeledValue(label: values[index].label, value: newValue as NSString)
                }
            } else {
                guard !newValue.isEmpty, values.count < 10,
                      !values.contains(where: {
                          ($0.value as String).caseInsensitiveCompare(newValue) == .orderedSame
                      }) else { throw Failure.duplicate }
                values.append(CNLabeledValue(label: CNLabelWork, value: newValue as NSString))
            }
            contact.emailAddresses = values
        case "phone":
            guard newValue.isEmpty || (7...20).contains(digits(newValue).count) else {
                throw Failure.invalidArguments
            }
            var values = contact.phoneNumbers
            if let oldValue {
                let matches = values.indices.filter {
                    values[$0].value.stringValue == oldValue
                }
                guard matches.count == 1, let index = matches.first else { throw Failure.ambiguous }
                if newValue.isEmpty {
                    values.remove(at: index)
                } else {
                    guard !values.contains(where: {
                        digits($0.value.stringValue) == digits(newValue)
                            && $0.value.stringValue != oldValue
                    }) else { throw Failure.duplicate }
                    values[index] = CNLabeledValue(
                        label: values[index].label, value: CNPhoneNumber(stringValue: newValue)
                    )
                }
            } else {
                guard !newValue.isEmpty, values.count < 10,
                      !values.contains(where: {
                          digits($0.value.stringValue) == digits(newValue)
                      }) else { throw Failure.duplicate }
                values.append(CNLabeledValue(
                    label: CNLabelWork, value: CNPhoneNumber(stringValue: newValue)
                ))
            }
            contact.phoneNumbers = values
        default:
            throw Failure.invalidArguments
        }
    }

    nonisolated private static func requiredText(
        _ args: [String: JSONValue], _ key: String, maximum: Int
    ) throws -> String {
        let value = try requiredTextAllowEmpty(args, key, maximum: maximum)
        guard !value.isEmpty else { throw Failure.invalidArguments }
        return value
    }

    nonisolated private static func requiredTextAllowEmpty(
        _ args: [String: JSONValue], _ key: String, maximum: Int
    ) throws -> String {
        guard case .string(let value)? = args[key],
              value.count <= maximum,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw Failure.invalidArguments
        }
        return value
    }

    nonisolated private static func optionalName(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        try requiredTextAllowEmpty(args, key, maximum: 120)
    }

    nonisolated private static func requireKeys(
        _ args: [String: JSONValue], _ keys: Set<String>
    ) throws {
        guard Set(args.keys) == keys else { throw Failure.invalidArguments }
    }

    nonisolated private static func requiredOptionalString(
        _ args: [String: JSONValue], _ key: String, maximum: Int
    ) throws -> String? {
        if case .null? = args[key] { return nil }
        return try requiredTextAllowEmpty(args, key, maximum: maximum)
    }

    nonisolated private static func stringArray(
        _ args: [String: JSONValue], _ key: String,
        maximumCount: Int, maximumLength: Int
    ) throws -> [String] {
        guard case .array(let values)? = args[key], values.count <= maximumCount else {
            throw Failure.invalidArguments
        }
        return try values.map { value in
            guard case .string(let item) = value,
                  !item.isEmpty, item.count <= maximumLength,
                  item == item.trimmingCharacters(in: .whitespacesAndNewlines),
                  item.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw Failure.invalidArguments
            }
            return item
        }
    }

    nonisolated private static func requiredEmail(
        _ args: [String: JSONValue], _ key: String
    ) throws -> String {
        let value = try requiredText(args, key, maximum: 254)
        guard validEmail(value) else { throw Failure.invalidArguments }
        return value
    }

    nonisolated private static func validEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return value.count <= 254 && parts.count == 2
            && !parts[0].isEmpty && !parts[1].isEmpty
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    nonisolated private static func digits(_ value: String) -> String {
        value.unicodeScalars
            .filter { (48...57).contains($0.value) }
            .map { String($0) }
            .joined()
    }
}
