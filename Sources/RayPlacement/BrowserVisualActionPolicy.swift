import Combine
import Foundation

enum BrowserNavigationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case adaptive
    case visualOnly
    case semanticOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .visualOnly: "Visual Only"
        case .semanticOnly: "Semantic Only"
        }
    }
}

enum BrowserApprovalMode: String, CaseIterable, Identifiable, Sendable {
    case askForActions
    case autoApproveNonpayment
    case independent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askForActions: "Ask for Actions"
        case .autoApproveNonpayment: "Approved Sites"
        case .independent: "Independent"
        }
    }
}

/// A non-persisted grant. Arming applies to one next AI run, never to every
/// conversation. The run's exact origins are established at start; the user
/// can explicitly add a visible or blocked destination in the Browser toolbar.
@MainActor
final class BrowserTaskApprovalState: ObservableObject {
    static let shared = BrowserTaskApprovalState()

    @Published private(set) var armedMode: BrowserApprovalMode = .askForActions
    @Published private(set) var activeMode: BrowserApprovalMode = .askForActions
    @Published private(set) var activeRunID: UUID?
    @Published private(set) var authorizedSites: Set<String> = []
    @Published private(set) var requestedSite: String?

    var displayMode: BrowserApprovalMode {
        activeRunID == nil ? armedMode : activeMode
    }

    func select(_ mode: BrowserApprovalMode) {
        if activeRunID == nil { armedMode = mode }
        else { activeMode = mode }
        if mode != .autoApproveNonpayment { requestedSite = nil }
    }

    func begin(runID: UUID, instruction: String, initialURL: String?) {
        // A new task cannot inherit the previous task's authority.
        activeRunID = runID
        activeMode = armedMode
        armedMode = .askForActions
        var sites = Self.explicitSites(in: instruction)
        // An explicit destination should not silently authorize an unrelated
        // selected tab. Use the current tab only when the task names no URL.
        if sites.isEmpty, let initialURL, let site = Self.site(initialURL) {
            sites.insert(site)
        }
        authorizedSites = sites
        requestedSite = nil
    }

    func end(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        activeMode = .askForActions
        authorizedSites = []
        requestedSite = nil
    }

    func authorizeVisibleSite(_ url: String?) {
        guard activeRunID != nil, let url, let site = Self.site(url) else { return }
        authorizedSites.insert(site)
        if requestedSite == site { requestedSite = nil }
    }

    func noteBlockedSite(_ url: String) {
        guard activeRunID != nil, activeMode == .autoApproveNonpayment,
              let site = Self.site(url), !authorizedSites.contains(site) else { return }
        requestedSite = site
    }

    func authorizeRequestedSite() {
        guard activeRunID != nil, activeMode == .autoApproveNonpayment,
              let requestedSite else { return }
        authorizedSites.insert(requestedSite)
        self.requestedSite = nil
    }

    func dismissRequestedSite() {
        requestedSite = nil
    }

    func isAutoApproved(runID: UUID?, url: String) -> Bool {
        guard let runID, activeRunID == runID,
              let site = Self.site(url) else { return false }
        if activeMode == .independent { return true }
        guard activeMode == .autoApproveNonpayment else { return false }
        // Exact scheme, host, and effective port: no cross-origin or subdomain inheritance.
        return authorizedSites.contains(site)
    }

    func isWithinScope(runID: UUID?, url: String) -> Bool {
        guard let runID, activeRunID == runID else { return false }
        if activeMode == .askForActions { return true }
        return isAutoApproved(runID: runID, url: url)
    }

    func requiresActionPrompt(runID: UUID?, toolID: String) -> Bool {
        guard let runID, activeRunID == runID,
              activeMode == .askForActions else { return false }
        return BrowserWorkspaceAITools.navigationIDs.contains(toolID) ||
            BrowserWorkspaceAITools.interactionIDs.contains(toolID)
    }

    static func host(_ url: String) -> String? {
        guard let safe = BrowserRuntime.safeDestination(url),
              let host = safe.host?.lowercased(), !host.isEmpty else { return nil }
        return safe.port.map { "\(host):\($0)" } ?? host
    }

    static func site(_ url: String) -> String? {
        guard let safe = BrowserRuntime.safeDestination(url),
              let scheme = safe.scheme?.lowercased(),
              let host = safe.host?.lowercased(), !host.isEmpty else { return nil }
        let port = safe.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    static func explicitSites(in instruction: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(instruction.startIndex..<instruction.endIndex, in: instruction)
        return Set(expression.matches(in: instruction, range: range).compactMap { match in
            guard let range = Range(match.range, in: instruction) else { return nil }
            return site(String(instruction[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!)]}")))
        })
    }
}

enum BrowserVisualActionDecision: Equatable, Sendable {
    case routine
    case review
    case blocked
}

/// The private WebKit safety probe supplies context, not a DOM target for AI
/// planning. A failed or incomplete probe never turns into an automatic click.
struct BrowserVisualActionAssessment: Decodable, Equatable, Sendable {
    let label: String
    let role: String
    let formLabel: String
    let isSubmit: Bool
    let isEditable: Bool
    let isCanvas: Bool
    let sensitive: Bool
    let disabled: Bool
    let financialContext: Bool
    let financialTerms: [String]
    let protectedContext: Bool

    var decision: BrowserVisualActionDecision {
        if sensitive || disabled || protectedContext { return .blocked }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // A nonsensitive text field is not itself a payment commitment, even
        // when it belongs to a checkout form. The submit control is reviewed.
        if isEditable { return .routine }
        let explicitPayment = matches(name + " " + formLabel,
            #"\b(pay|purchase|buy now|charge|authorize payment|place order|complete order|subscribe|donate|pledge|send money|transfer funds|deposit|checkout)\b"#)
        if explicitPayment { return .review }
        // A search-like label cannot exempt a submit button in a financial form.
        // Unlabelled canvas controls have no trustworthy ordinary-action meaning.
        if financialContext && isSubmit { return .review }
        if isCanvas && name.isEmpty { return .review }
        let clearlyExploratory = matches(name,
            #"^(find|search|check availability|show results|see availability|filter|look up|lookup|view|add to cart|select|choose)\b"#)
        let ambiguousFinal = name.isEmpty || matches(name,
            #"^(continue|next|proceed|done|confirm|complete|submit|finish|place|authorize|send|accept|agree|yes|reserve|book)\b"#)
        let financialConsent = matches(name, #"\b(accept|agree|consent|authorize)\b"#)
        let clearlyOrdinarySubmission = isSubmit &&
            !financialContext && financialTerms.isEmpty &&
            matches(name,
                #"^(?:submit|send|post) (?:feedback|review|comment|reply|message|inquiry|enquiry|question|contact form)(?: now)?$|^save draft$"#) &&
            !matches(formLabel, #"\b(account|security|password|verification|payment|billing|checkout|order|reservation|booking)\b"#)
        if clearlyOrdinarySubmission { return .routine }
        if (financialContext || !financialTerms.isEmpty) &&
           (isSubmit || ambiguousFinal || financialConsent || isCanvas) && !clearlyExploratory {
            return .review
        }
        // An ambiguous final-looking visual control may commit a booking or
        // payment through JavaScript even without a native submit element or
        // visible fee terms. Uncertainty never qualifies for auto-approval.
        if !clearlyExploratory && ambiguousFinal { return .review }
        return .routine
    }

    func requiresReview(independent: Bool) -> Bool {
        decision == .review && (!independent || potentialPaymentCommitment)
    }

    var potentialPaymentCommitment: Bool {
        guard decision == .review else { return false }
        return financialContext || !financialTerms.isEmpty || matches(
            label + " " + formLabel,
            #"\b(pay|purchase|buy now|charge|authorize payment|place order|complete order|subscribe|donate|pledge|send money|transfer funds|deposit|checkout)\b"#
        )
    }

    private func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
