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

    var userSummary: String {
        if isVisual {
            return "Review a visual click on “\(label)” at \(host). Lima identified this point in the current Browser screenshot, but page semantics cannot establish its consequences. Allow this exact click only if intended."
        }
        let actionText = label.isEmpty ? "a final web action" : "“\(label)”"
        let form = formLabel.map { " in the \($0) form" } ?? ""
        let terms = visibleTerms.isEmpty ? "" :
            " Visible terms to review: " + visibleTerms.joined(separator: " · ")
        return "Review \(actionText)\(form) on \(host). This may submit a real transaction.\(terms)"
    }
}

enum BrowserCommitAuthorization {
    /// Discovery/search submissions are not final transactions. All other form
    /// submissions are reviewed unless their exact visible label is clearly a
    /// non-final search/navigation step. An ambiguous "Continue" remains gated.
    static func visualReview(hit: BrowserVisualHit) -> BrowserCommitReview {
        BrowserCommitReview(
            tabID: hit.tabID, targetID: hit.id.uuidString, action: "pointerClick",
            label: String(hit.label.prefix(160)),
            host: URLComponents(string: hit.pageIdentity.url)?.host ?? "this site",
            formLabel: nil, visibleTerms: [], isVisual: true,
            pageIdentity: hit.pageIdentity
        )
    }

    static func review(tabID: UUID, target: BrowserTarget,
                       action: BrowserInteractionAction,
                       page: BrowserPageSnapshot) -> BrowserCommitReview? {
        guard action == .click || action == .submit else { return nil }
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
        let isCommit = financialRisk || (!clearlyNonFinal && (action == .submit || labelIsFinal ||
            (transactionForm && ambiguousAction &&
             ["button", "link", "genericClickable"].contains(target.role))))
        guard isCommit else { return nil }
        let host = URLComponents(string: page.identity.url)?.host ?? "this site"
        let terms = page.text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                $0.count <= 200 &&
                $0.range(of: #"\b(deposit|fee|charge|total|non.?refund|cancel(?:lation)? policy)\b|\$\s?\d"#,
                         options: [.regularExpression, .caseInsensitive]) != nil
            }
            .prefix(3)
            .map { String($0.prefix(140)) }
        return BrowserCommitReview(
            tabID: tabID, targetID: target.id, action: action.rawValue,
            label: String(label.prefix(160)), host: host,
            formLabel: target.formLabel.map { String($0.prefix(100)) },
            visibleTerms: Array(terms), isVisual: false,
            pageIdentity: page.identity
        )
    }
}
