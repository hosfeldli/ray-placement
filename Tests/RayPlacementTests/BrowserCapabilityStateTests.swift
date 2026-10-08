import Foundation
import Testing
@testable import RayPlacement

private func capabilityContext(
    enabled: Set<String> = BrowserCapabilityTurnContext.readToolIDs.union(BrowserCapabilityTurnContext.navigationToolIDs).union(BrowserCapabilityTurnContext.interactionToolIDs),
    inTurn: Set<String> = BrowserCapabilityTurnContext.readToolIDs.union(BrowserCapabilityTurnContext.navigationToolIDs).union(BrowserCapabilityTurnContext.interactionToolIDs),
    agentID: String? = nil,
    agentTools: Set<String>? = nil,
    pendingApproval: Bool = false
) -> BrowserCapabilityTurnContext {
    BrowserCapabilityTurnContext(
        selectedAgentID: agentID,
        selectedAgentToolIDs: agentTools,
        enabledToolIDs: enabled,
        turnToolIDs: inTurn,
        pendingApproval: pendingApproval
    )
}

private func makeCapabilities(
    connected: Bool = true,
    permissionsAvailable: Bool = true,
    readOrigins: [String] = ["https://salesforce.example"],
    broadGrant: Bool = false,
    broadEnabled: Bool = false,
    interactionOrigins: [String] = ["https://salesforce.example"],
    companionInteraction: Bool = true,
    interactionPolicyAvailable: Bool = true,
    navigation: AIComputerActionAccess = .allowWithJournal,
    interaction: AIComputerActionAccess = .allowWithJournal,
    context: BrowserCapabilityTurnContext = capabilityContext()
) -> BrowserCapabilityState {
    BrowserCapabilityState(
        bridgeEnabled: true,
        companionConnected: connected,
        permissionStatusAvailable: permissionsAvailable,
        exactReadOrigins: readOrigins,
        broadHTTPSGrantInstalled: broadGrant,
        broadHTTPSReadingEnabled: broadEnabled,
        exactInteractionOrigins: interactionOrigins,
        companionSupportsInteraction: companionInteraction,
        interactionPolicyAvailable: interactionPolicyAvailable,
        navigationAccess: navigation,
        interactionAccess: interaction,
        context: context
    )
}

@Test func disconnectedCompanionBlocksEveryBrowserCapability() {
    let state = makeCapabilities(connected: false)

    #expect(state.read.status == .bridgeDisconnected)
    #expect(state.navigation.status == .bridgeDisconnected)
    #expect(state.interaction.status == .bridgeDisconnected)
}

@Test func readCanBeAvailableWhileNavigationIsDisabled() {
    let state = makeCapabilities(
        navigation: .disabled,
        context: capabilityContext(inTurn: BrowserCapabilityTurnContext.readToolIDs)
    )

    #expect(state.read.status == .available)
    #expect(state.navigation.status == .disabledInSettings)
}

@Test func capabilityProjectionDistinguishesMissingSiteGrantAndIgnoresAgentToolLists() {
    let missingGrant = makeCapabilities(readOrigins: [], interactionOrigins: [])
    #expect(missingGrant.read.status == .siteNotGranted)
    #expect(missingGrant.interaction.status == .siteNotGranted)

    let excluded = makeCapabilities(
        context: capabilityContext(
            inTurn: BrowserCapabilityTurnContext.readToolIDs.union(BrowserCapabilityTurnContext.navigationToolIDs),
            agentID: "research-agent",
            agentTools: ["notes_search"]
        )
    )
    #expect(excluded.read.status == .available)
    #expect(excluded.navigation.status == .available)
}

@Test func broadReadGrantRequiresSeparateExperimentalSetting() {
    let state = makeCapabilities(readOrigins: [], broadGrant: true, broadEnabled: false)

    #expect(state.read.status == .broadGrantDisabled)
    #expect(state.navigation.status == .broadGrantDisabled)
}

@Test func interactionReportsApprovalAndAlwaysRequiresSubmitApproval() {
    let context = capabilityContext(pendingApproval: true)
    let state = makeCapabilities(context: context)

    #expect(state.interaction.status == .requiresApproval)
    #expect(state.interactionSubmitRequiresApproval)
}

@Test func originInspectionDistinguishesGrantedSalesforceFromUngrantedGoogle() {
    let state = makeCapabilities()
    let salesforce = state.decisions(forOrigin: "https://salesforce.example")
    let google = state.decisions(forOrigin: "https://www.google.com")

    #expect(salesforce.origin == "https://salesforce.example")
    #expect(salesforce.read.status == .available)
    #expect(salesforce.navigation.status == .available)
    #expect(salesforce.interaction.status == .available)
    #expect(google.read.status == .siteNotGranted)
    #expect(google.navigation.status == .siteNotGranted)
    #expect(google.interaction.status == .siteNotGranted)
}

@Test func broadGrantCanCoverTargetReadsAndNavigationButNeverInteraction() {
    let state = makeCapabilities(readOrigins: [], broadGrant: true, broadEnabled: true, interactionOrigins: [])
    let target = state.decisions(forOrigin: "https://maps.google.com")

    #expect(target.read.status == .available)
    #expect(target.navigation.status == .available)
    #expect(target.interaction.status == .siteNotGranted)

    let disabled = makeCapabilities(readOrigins: [], broadGrant: true, broadEnabled: false, interactionOrigins: [])
        .decisions(forOrigin: "https://maps.google.com")
    #expect(disabled.read.status == .broadGrantDisabled)
    #expect(disabled.navigation.status == .broadGrantDisabled)
}

@Test func originInspectionRejectsNonHTTPSPathsAndRetainsSettingsBlockers() {
    let state = makeCapabilities(navigation: .disabled)
    #expect(state.decisions(forOrigin: "http://salesforce.example").read.status == .invalidOrigin)
    #expect(state.decisions(forOrigin: "https://salesforce.example/report").read.status == .invalidOrigin)
    #expect(state.decisions(forOrigin: "https://salesforce.example").navigation.status == .disabledInSettings)
}
