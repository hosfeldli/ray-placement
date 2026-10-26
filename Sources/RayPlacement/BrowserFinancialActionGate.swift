import Foundation

/// Native policy signal for possible monetary commitments. This classifier can
/// only require more review; it never authorizes an action or waives the
/// existing exact-call approval boundary.
enum BrowserFinancialActionGate {
    static func requiresReview(target: BrowserTarget, action: BrowserInteractionAction,
                               page: BrowserPageSnapshot) -> Bool {
        guard [.click, .submit, .toggle, .select, .pressKey].contains(action) else {
            return false
        }

        let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitMoneyAction = matches(
            label,
            #"\b(pay|purchase|buy|charge|authorize payment|confirm order|place order|complete order|subscribe|start subscription|donate|pledge|transfer funds|send money|accept fee|pay deposit)\b"#
        )
        if explicitMoneyAction { return true }

        // An exploratory-sounding label cannot exempt a submit control inside
        // a financial form. Sites can rename the final control to "Search" or
        // "Continue"; the native gate must classify the form, not only its text.
        let financialForm = matches(
            target.formLabel ?? "",
            #"\b(checkout|payment|billing|order|subscription|donation|deposit|transfer)\b"#
        )
        if financialForm && (action == .submit || target.isSubmit == true) {
            return true
        }

        let clearlyExploratory = matches(
            label,
            #"^(find|search|check availability|show results|see availability|filter|look up|lookup|view)\b"#
        )
        let context = [page.title, target.formLabel ?? "",
                       URLComponents(string: page.identity.url)?.path ?? ""]
            .joined(separator: " ")
        let checkoutContext = matches(
            context,
            #"\b(checkout|payment|billing|order review|order summary|cart|subscription|donation|transfer funds|deposit)\b"#
        )
        // Toggle, select, and synthetic key handlers can execute page script.
        // On a payment form or checkout surface, they cannot silently become
        // a second path around the final-action boundary.
        if [.toggle, .select, .pressKey].contains(action) {
            let feeConsent = matches(label, #"\b(agree|accept|consent|authorize|approve|confirm)\b"#) &&
                matches(page.text,
                    #"\b(deposit|charge|fee|card hold|recurring|subscription|amount due|payment method|non.?refund)\b|\$\s?\d"#)
            return financialForm || checkoutContext || feeConsent
        }
        // Availability searches on a booking page are not commitments, even
        // when a later reservation might require a fee. A checkout submit is
        // less certain: search-like copy cannot exempt it from review.
        if clearlyExploratory && !checkoutContext { return false }
        let bookingContext = matches(
            context,
            #"\b(reservation|booking|appointment|registration)\b"#
        )
        let financialTerms = matches(
            page.text,
            #"\b(total|deposit|charge|fee|card hold|recurring|subscription|amount due|payment method|non.?refund)\b|\$\s?\d"#
        )
        guard checkoutContext || (bookingContext && financialTerms) else { return false }

        let ambiguousCommit = label.isEmpty || matches(
            label,
            #"^(continue|next|proceed|done|confirm|complete|submit|finish|place|authorize|send|accept|agree|yes)\b"#
        )
        let actionableRole = ["button", "link", "genericClickable"].contains(target.role)
        return action == .submit || target.isSubmit == true ||
            (actionableRole && ambiguousCommit)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
