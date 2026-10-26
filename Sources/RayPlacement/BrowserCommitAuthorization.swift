import Foundation

/// A conservative, site-agnostic boundary between ordinary Browser interaction
/// and a final transaction. This policy does not authorize itself: only a trusted
/// tool-continuation approval for the exact call may permit a commit.
struct BrowserCommitReview: Sendable, Equatable {
    let tabID: UUID
    let targetID: String
    let action: String
    let label: String
    let host: String
    let formLabel: String?
    let visibleTerms: [String]
    let isVisual: Bool
    /// Binds the review to the exact page state that supplied its terms.
    let pageIdentity: BrowserPageIdentity
    var typedText: String? = nil
    var requiresPaymentConfirmation: Bool = false

    var userSummary: String {
        if isVisual {
            if action == "nativeType" {
                let field = label.isEmpty ? "the selected text field" : "“\(label)”"
                let value = typedText.map { " Text to type: “\($0)”." } ?? ""
                return "Review native typing into \(field) at \(host).\(value) Lima will not use the clipboard. Protected fields remain unavailable."
            }
            let terms = visibleTerms.isEmpty ? "" :
                " Visible terms to review: " + visibleTerms.joined(separator: " · ")
            let warning = requiresPaymentConfirmation
                ? "Possible payment or financial commitment. " : ""
            return "\(warning)Review a visual click on “\(label)” at \(host). Lima identified this point in the current Browser screenshot, but page semantics cannot establish its consequences.\(terms) Allow this exact click only if intended."
        }
        let actionText = label.isEmpty ? "a final web action" : "“\(label)”"
        let form = formLabel.map { " in the \($0) form" } ?? ""
        let terms = visibleTerms.isEmpty ? "" :
            " Visible terms to review: " + visibleTerms.joined(separator: " · ")
        let warning = requiresPaymentConfirmation
            ? "Possible payment or financial commitment. " : ""
        return "\(warning)Review \(actionText)\(form) on \(host). This may submit a real transaction.\(terms)"
    }
}

enum BrowserCommitAuthorization {
    /// Discovery/search submissions are not final transactions. All other form
    /// submissions are reviewed unless their exact visible label is clearly a
    /// non-final search/navigation step. An ambiguous "Continue" remains gated.
    static func visualReview(hit: BrowserVisualHit,
                             page: BrowserPageSnapshot) -> BrowserCommitReview? {
        guard page.identity == hit.pageIdentity else { return nil }
        return BrowserCommitReview(
            tabID: hit.tabID, targetID: hit.id.uuidString, action: "pointerClick",
            label: String(hit.label.prefix(160)),
            host: URLComponents(string: hit.pageIdentity.url)?.host ?? "this site",
            formLabel: nil, visibleTerms: visibleTerms(in: page), isVisual: true,
            pageIdentity: hit.pageIdentity
        )
    }

    static func review(tabID: UUID, target: BrowserTarget,
                       action: BrowserInteractionAction,
                       page: BrowserPageSnapshot,
                       autoApproveNonpayment: Bool = false) -> BrowserCommitReview? {
        guard [.click, .submit, .toggle, .select, .pressKey].contains(action) else {
            return nil
        }
        let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPattern = #"\b(reserve|reservation|book|booking|confirm|complete|register|registration|subscribe|checkout|order|purchase|buy|pay|payment|donate|pledge|transfer|send money|accept|agree|finali[sz]e|finish|submit|schedule appointment|place registration)\b"#
        let labelIsFinal = label.range(of: finalPattern, options: [.regularExpression, .caseInsensitive]) != nil
        let transactionForm = (target.formLabel ?? "").range(
            of: #"\b(reservation|booking|registration|checkout|order|appointment|payment)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let ambiguousAction = label.range(
            of: #"^(continue|next|proceed|done|go|yes)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let clearlyNonFinal = label.range(
            of: #"^(find|search|check availability|show results|see availability|filter|look up|lookup|view)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil && !labelIsFinal
        // A form's name is context, not a final action: clicking its calendar
        // cells, combobox, or option must not be mistaken for submission.
        let financialRisk = BrowserFinancialActionGate.requiresReview(
            target: target, action: action, page: page
        )
        let isCommit = financialRisk || (
            [.click, .submit].contains(action) && !clearlyNonFinal &&
            (action == .submit || labelIsFinal ||
             (transactionForm && ambiguousAction &&
              ["button", "link", "genericClickable"].contains(target.role)))
        )
        guard isCommit else { return nil }
        // Only explicitly nonfinancial form submissions may skip the normal
        // final-action prompt. Unknown submits, bookings, payments, and account
        // changes retain review even when the task has an auto-approval grant.
        if autoApproveNonpayment && !financialRisk &&
           confidentlyOrdinarySubmission(target: target, action: action, page: page) {
            return nil
        }
        let host = URLComponents(string: page.identity.url)?.host ?? "this site"
        let terms = visibleTerms(in: page)
        return BrowserCommitReview(
            tabID: tabID, targetID: target.id, action: action.rawValue,
            label: String(label.prefix(160)), host: host,
            formLabel: target.formLabel.map { String($0.prefix(100)) },
            visibleTerms: terms, isVisual: false,
            pageIdentity: page.identity,
            requiresPaymentConfirmation: financialRisk
        )
    }

    private static func confidentlyOrdinarySubmission(
        target: BrowserTarget, action: BrowserInteractionAction,
        page: BrowserPageSnapshot
    ) -> Bool {
        guard action == .submit || target.isSubmit == true else { return false }
        let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.range(
            of: #"^(?:submit|send|post) (?:feedback|review|comment|reply|message|inquiry|enquiry|question|contact form)(?: now)?$|^save draft$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { return false }
        let context = [page.title, target.formLabel ?? "",
                       URLComponents(string: page.identity.url)?.path ?? "", page.text]
            .joined(separator: " ")
        return context.range(
            of: #"\b(checkout|payment|billing|order|reservation|booking|deposit|fee|charge|card hold|subscription|transfer|money|account|security|password|authentication|verification|captcha|delete|deactivate|revoke)\b|\$\s?\d"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil
    }

    private static func visibleTerms(in page: BrowserPageSnapshot) -> [String] {
        page.text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                $0.count <= 200 &&
                $0.range(of: #"\b(deposit|fee|charge|total|non.?refund|cancel(?:lation)? policy)\b|\$\s?\d"#,
                         options: [.regularExpression, .caseInsensitive]) != nil
            }
            .prefix(3)
            .map { String($0.prefix(140)) }
    }
}
