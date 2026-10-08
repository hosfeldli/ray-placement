import Foundation

/// A stable, machine-readable reason for a browser capability's current state.
enum BrowserCapabilityStatus: String, Codable, Sendable {
    case available
    case unavailable
    case disabledInSettings
    case toolGroupDisabled
    case agentExcluded
    case siteNotGranted
    case broadGrantDisabled
    case bridgeDisconnected
    case incompatibleCompanion
    case requiresApproval
    case notInTurn
    case invalidOrigin
}

struct BrowserCapabilityDecision: Codable, Equatable, Sendable {
    let status: BrowserCapabilityStatus
    let reason: String?

    static func available(_ reason: String? = nil) -> Self { .init(status: .available, reason: reason) }
    static func blocked(_ status: BrowserCapabilityStatus, _ reason: String) -> Self {
        .init(status: status, reason: reason)
    }
}

/// Immutable routing context captured at the start of a provider turn. This is
/// diagnostic input only; actual tool execution still rechecks live permissions.
struct BrowserCapabilityTurnContext: Equatable, Sendable {
    let selectedAgentID: String?
    let selectedAgentToolIDs: Set<String>?
    let enabledToolIDs: Set<String>
    let turnToolIDs: Set<String>
    let pendingApproval: Bool

    static let readToolIDs: Set<String> = [
        "browser_tabs", "browser_current", "browser_read",
        "browser_capabilities", "salesforce_read_case_links", "salesforce_resolve_case", "salesforce_resolve_cases"
    ]
    static let navigationToolIDs: Set<String> = ["browser_open_tabs", "browser_focus_tab", "browser_navigate_tab"]
    static let interactionToolIDs: Set<String> = ["browser_click", "browser_type", "browser_submit"]

    func agentAllows(_ toolIDs: Set<String>) -> Bool {
        guard selectedAgentID != nil else { return true }
        return !(selectedAgentToolIDs ?? []).isDisjoint(with: toolIDs)
    }

    func isEnabled(_ toolIDs: Set<String>) -> Bool { !enabledToolIDs.isDisjoint(with: toolIDs) }
    func isInTurn(_ toolIDs: Set<String>) -> Bool { !turnToolIDs.isDisjoint(with: toolIDs) }
}

/// One authoritative, read-only projection of bridge, grant, action-policy,
/// selected-agent, and per-turn tool routing state.
struct BrowserCapabilityState: Equatable, Sendable {
    let read: BrowserCapabilityDecision
    let navigation: BrowserCapabilityDecision
    let interaction: BrowserCapabilityDecision
    let exactReadOrigins: [String]
    let exactInteractionOrigins: [String]
    let broadHTTPSGrantInstalled: Bool
    let broadHTTPSReadingEnabled: Bool
    let interactionSubmitRequiresApproval = true

    struct OriginDecisions: Equatable, Sendable {
        let origin: String?
        let read: BrowserCapabilityDecision
        let navigation: BrowserCapabilityDecision
        let interaction: BrowserCapabilityDecision
    }

    /// Refines aggregate capability state for one HTTPS origin. Exact browser
    /// grants match host only; broad HTTPS grants apply to reads/navigation only.
    func decisions(forOrigin rawOrigin: String) -> OriginDecisions {
        guard let origin = Self.normalizedHTTPSOrigin(rawOrigin),
              let host = URL(string: origin)?.host?.lowercased() else {
            let invalid = BrowserCapabilityDecision.blocked(.invalidOrigin, "Provide an HTTPS origin without a port or embedded credentials.")
            return OriginDecisions(origin: nil, read: invalid, navigation: invalid, interaction: invalid)
        }

        let exactRead = exactReadOrigins.contains { Self.host(inOrigin: $0) == host }
        let broadRead = broadHTTPSGrantInstalled && broadHTTPSReadingEnabled
        let readGrant = exactRead || broadRead
        let readMissing = broadHTTPSGrantInstalled && !broadHTTPSReadingEnabled
            ? BrowserCapabilityDecision.blocked(.broadGrantDisabled, "The target origin is covered only by a broad HTTPS grant, but Lima's Broad HTTPS experiment is off.")
            : BrowserCapabilityDecision.blocked(.siteNotGranted, "The target origin is not granted in the selected browser session.")

        let navigationDecision = Self.scoped(navigation, allowed: readGrant, missing: readMissing)
        let readDecision = Self.scoped(read, allowed: readGrant, missing: readMissing)
        let interactionAllowed = exactInteractionOrigins.contains { Self.host(inOrigin: $0) == host }
        let interactionMissing = BrowserCapabilityDecision.blocked(.siteNotGranted, "Browser interaction requires an exact-site grant for the target origin; broad HTTPS grants do not apply.")
        let interactionDecision = Self.scoped(interaction, allowed: interactionAllowed, missing: interactionMissing)

        return OriginDecisions(origin: origin, read: readDecision, navigation: navigationDecision, interaction: interactionDecision)
    }

    private static func scoped(_ decision: BrowserCapabilityDecision, allowed: Bool, missing: BrowserCapabilityDecision) -> BrowserCapabilityDecision {
        switch decision.status {
        case .available, .requiresApproval, .siteNotGranted, .broadGrantDisabled:
            guard allowed else { return missing }
            if decision.status == .siteNotGranted || decision.status == .broadGrantDisabled {
                return .available("The target origin is granted.")
            }
            return decision
        default:
            return decision
        }
    }

    private static func normalizedHTTPSOrigin(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        return "https://\(host)"
    }

    private static func host(inOrigin origin: String) -> String? {
        URL(string: origin)?.host?.lowercased()
    }

    init(
        bridgeEnabled: Bool,
        companionConnected: Bool,
        permissionStatusAvailable: Bool,
        exactReadOrigins: [String],
        broadHTTPSGrantInstalled: Bool,
        broadHTTPSReadingEnabled: Bool,
        exactInteractionOrigins: [String],
        companionSupportsInteraction: Bool,
        interactionPolicyAvailable: Bool,
        navigationAccess: AIComputerActionAccess,
        interactionAccess: AIComputerActionAccess,
        context: BrowserCapabilityTurnContext
    ) {
        self.exactReadOrigins = exactReadOrigins.sorted()
        self.exactInteractionOrigins = exactInteractionOrigins.sorted()
        self.broadHTTPSGrantInstalled = broadHTTPSGrantInstalled
        self.broadHTTPSReadingEnabled = broadHTTPSReadingEnabled

        func bridgeBlock() -> BrowserCapabilityDecision? {
            if !bridgeEnabled { return .blocked(.unavailable, "Browser Bridge is disabled in Lima Settings.") }
            if !companionConnected { return .blocked(.bridgeDisconnected, "No compatible Zen or Firefox companion session is connected.") }
            return nil
        }

        if let blocked = bridgeBlock() {
            read = blocked
            navigation = blocked
            interaction = blocked
            return
        }
        if !permissionStatusAvailable {
            let unavailable = BrowserCapabilityDecision.blocked(.unavailable, "Browser permission status could not be verified from the companion.")
            read = unavailable
            navigation = unavailable
            interaction = unavailable
            return
        }

        let readableTools = BrowserCapabilityTurnContext.readToolIDs.subtracting(["browser_capabilities"])
        if !context.agentAllows(readableTools) {
            read = .blocked(.agentExcluded, "The selected agent excludes browser-read tools.")
        } else if !context.isEnabled(readableTools) {
            read = .blocked(.toolGroupDisabled, "Enable the Browser read tools in the AI Tools menu.")
        } else if !context.isInTurn(readableTools) {
            read = .blocked(.notInTurn, "Browser read tools were not routed for this model turn.")
        } else if exactReadOrigins.isEmpty && !broadHTTPSGrantInstalled {
            read = .blocked(.siteNotGranted, "No exact HTTPS site grants are available in the selected browser session.")
        } else if exactReadOrigins.isEmpty && broadHTTPSGrantInstalled && !broadHTTPSReadingEnabled {
            read = .blocked(.broadGrantDisabled, "The browser has an all-HTTPS grant, but Lima's Broad HTTPS experiment is off.")
        } else {
            read = .available(exactReadOrigins.isEmpty ? "Broad HTTPS reading is enabled." : nil)
        }

        if !context.agentAllows(BrowserCapabilityTurnContext.navigationToolIDs) {
            navigation = .blocked(.agentExcluded, "The selected agent excludes browser-navigation tools.")
        } else if navigationAccess == .disabled {
            navigation = .blocked(.disabledInSettings, "Browser navigation is disabled in AI Settings.")
        } else if !context.isEnabled(BrowserCapabilityTurnContext.navigationToolIDs) {
            navigation = .blocked(.toolGroupDisabled, "Enable Browser navigation in the AI Tools menu.")
        } else if !context.isInTurn(BrowserCapabilityTurnContext.navigationToolIDs) {
            navigation = .blocked(.notInTurn, "Navigation tools were not routed for this model turn.")
        } else if exactReadOrigins.isEmpty && !(broadHTTPSGrantInstalled && broadHTTPSReadingEnabled) {
            navigation = .blocked(broadHTTPSGrantInstalled ? .broadGrantDisabled : .siteNotGranted,
                                  "The destination must have an exact site grant or an enabled broad HTTPS grant.")
        } else if navigationAccess == .askEveryTime {
            navigation = .blocked(.requiresApproval, "Lima asks for approval before each navigation action.")
        } else {
            navigation = .available("Navigation is journaled when used.")
        }

        if !interactionPolicyAvailable || interactionAccess == .disabled {
            interaction = .blocked(.disabledInSettings, "Browser AI interaction is disabled in Experimental Features or AI Settings.")
        } else if !context.agentAllows(BrowserCapabilityTurnContext.interactionToolIDs) {
            interaction = .blocked(.agentExcluded, "The selected agent excludes browser-interaction tools.")
        } else if !context.isEnabled(BrowserCapabilityTurnContext.interactionToolIDs) {
            interaction = .blocked(.toolGroupDisabled, "Enable Browser interaction in the AI Tools menu.")
        } else if !context.isInTurn(BrowserCapabilityTurnContext.interactionToolIDs) {
            interaction = .blocked(.notInTurn, "Interaction tools were not routed for this model turn.")
        } else if !companionSupportsInteraction {
            interaction = .blocked(.incompatibleCompanion, "The signed companion does not advertise browser_interaction_v1.")
        } else if exactInteractionOrigins.isEmpty {
            interaction = .blocked(.siteNotGranted, "Interaction requires a separate exact-site grant in the companion; broad HTTPS read grants do not apply.")
        } else if context.pendingApproval || interactionAccess == .askEveryTime {
            interaction = .blocked(.requiresApproval, "Lima asks before browser interactions; form submission always requires an individual approval.")
        } else {
            interaction = .available("Click and type use the selected journal policy; form submission still asks for approval.")
        }
    }
}
