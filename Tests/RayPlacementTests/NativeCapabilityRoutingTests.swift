import Foundation
import RayPlacementCore
import Testing
@testable import RayPlacement

@Test @MainActor func nativeCapabilityDefinitionsAreStrictAndOptIn() {
    #expect(NativeCapabilityAITools.ids.count == 34)
    #expect(NativeCapabilityAITools.definitions.count == NativeCapabilityAITools.ids.count)
    for definition in NativeCapabilityAITools.definitions {
        #expect(definition.responsePayload != nil)
        #expect(definition.actionCategory == .screenshotHistory ||
                definition.actionCategory == .screenCapture ||
                definition.actionCategory == .audioOutput ||
                definition.actionCategory == .networkQuality ||
                definition.actionCategory == .calendar ||
                definition.actionCategory == .reminders ||
                definition.actionCategory == .location)
        #expect(AIComputerActionPolicy.shared.requiresApproval(
            for: definition, toolAccessMode: .fullControl
        ))
    }
    #expect(NativeCapabilityRouter.supportedOperations.contains(.screenshotList))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.audioSetOutput))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.screenshotTargets))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.screenshotCapture))
    #expect(!NativeCapabilityRouter.supportedOperations.contains(.screenshotSave))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.networkTestStart))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.networkTestCancel))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.calendarCreateEvent))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.calendarUpdateEvent))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.calendarDeleteEvent))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.remindersCreate))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.remindersUpdate))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.remindersComplete))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.remindersDelete))
    #expect(NativeCapabilityRouter.supportedOperations.contains(.locationCurrent))
    #expect(!NativeCapabilityRouter.supportedOperations.contains(.calendarOpenEvent))
}

@Test func nativeExtensionActionInfersOnlyItsDedicatedCapability() throws {
    let action = ExtensionAction(
        type: .nativeCapability, operation: NativeCapabilityOperation.audioSetOutput.rawValue,
        parameters: ["uid": "device-uid"]
    )
    #expect(action.inferredCapabilities == [.audioOutput])
    do {
        try ExtensionAction.validateNativeChain([action])
        Issue.record("Native service calls must not be hidden in a chained action")
    } catch {
        #expect(error as? ExtensionAction.ChainValidationError ==
                .unsupportedAction(.nativeCapability))
    }
}

@Test @MainActor func nativeApprovalMatchesExactCallAndExpires() {
    let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let call = AIOutputItem(
        phase: .completed, apiType: "function_call",
        callID: "native-approved-fixture", name: "audio_set_output",
        arguments: "{\"uid\":\"device-a\"}"
    )
    let approval = AIToolApprovalRequest(
        localCallID: "native-approved-fixture", localToolID: "audio_set_output",
        serverLabel: "Lima", toolName: "audio_set_output",
        arguments: "{\"uid\":\"device-a\"}", createdAt: reviewedAt
    )
    #expect(NativeCapabilityAITools.matchesApproval(
        approval, call: call, now: reviewedAt.addingTimeInterval(119)
    ))
    #expect(!NativeCapabilityAITools.matchesApproval(
        approval, call: call, now: reviewedAt.addingTimeInterval(121)
    ))
    let changedArgument = AIOutputItem(
        phase: .completed, apiType: "function_call",
        callID: "native-approved-fixture", name: "audio_set_output",
        arguments: "{\"uid\":\"device-b\"}"
    )
    #expect(!NativeCapabilityAITools.matchesApproval(
        approval, call: changedArgument, now: reviewedAt
    ))
    let changedCallID = AIOutputItem(
        phase: .completed, apiType: "function_call",
        callID: "different-call", name: "audio_set_output",
        arguments: "{\"uid\":\"device-a\"}"
    )
    #expect(!NativeCapabilityAITools.matchesApproval(
        approval, call: changedCallID, now: reviewedAt
    ))
    var changedTool = approval
    changedTool.localToolID = "audio_get_output"
    #expect(!NativeCapabilityAITools.matchesApproval(
        changedTool, call: call, now: reviewedAt
    ))
}

@Test @MainActor func networkTestWithoutExactApprovalNeverStarts() async {
    let call = AIOutputItem(
        phase: .completed, apiType: "function_call",
        callID: "network-denied-fixture", name: "network_test_start",
        arguments: "{}"
    )
    let result = await NativeCapabilityAITools.execute(
        call, approvalGranted: false, runID: UUID()
    )
    #expect(result.isError)
    #expect(result.output.contains("exact-call approval"))
}

@Test @MainActor func nativeToolWithoutExactApprovalNeverReachesHardware() async {
    let call = AIOutputItem(
        phase: .completed, apiType: "function_call",
        callID: "native-denied-fixture", name: "audio_set_output",
        arguments: "{\"uid\":\"not-a-device\"}"
    )
    let result = await NativeCapabilityAITools.execute(
        call, approvalGranted: false, runID: UUID()
    )
    #expect(result.isError)
    #expect(result.output.contains("exact-call approval"))
}

@Test @MainActor func screenshotCaptureRequiresOneUseReviewBeforeScreenEnumeration() async {
    let runID = UUID()
    for name in ["screenshot_targets", "screenshot_capture"] {
        let call = AIOutputItem(
            phase: .completed, apiType: "function_call",
            callID: "capture-denied-\(name)", name: name,
            arguments: name == "screenshot_targets" ? "{}" : "{\"target_id\":\"display:1\"}"
        )
        let result = await NativeCapabilityAITools.execute(
            call, approvalGranted: true, runID: runID
        )
        #expect(result.isError)
        #expect(result.output.contains("exact-call approval"))
    }
    #expect(NativeCapabilityOperation.screenshotTargets.capability == .screenCapture)
    #expect(AIComputerActionPolicy.shared.access(for: .screenCapture) == .disabled)
}

@Test @MainActor func nativeApprovalBooleanCannotBypassOneUseCallBinding() async {
    let runID = UUID()
    let call = AIOutputItem(
        phase: .completed, apiType: "function_call",
        callID: "native-one-use-fixture", name: "network_test_status",
        arguments: "{}"
    )
    let forged = await NativeCapabilityAITools.execute(
        call, approvalGranted: true, runID: runID
    )
    #expect(forged.isError)
    #expect(forged.output.contains("exact-call approval"))

    let approval = AIToolApprovalRequest(
        localCallID: "native-one-use-fixture", localToolID: "network_test_status",
        serverLabel: "Lima", toolName: "network_test_status", arguments: "{}"
    )
    #expect(NativeCapabilityAITools.recordExactApproval(approval, call: call, runID: runID))
    #expect(!NativeCapabilityAITools.consumeExactApproval(for: call, runID: UUID()))
    let changed = AIOutputItem(
        phase: .completed, apiType: "function_call",
        callID: "native-one-use-fixture", name: "network_test_status",
        arguments: "{\"changed\":true}"
    )
    #expect(!NativeCapabilityAITools.consumeExactApproval(for: changed, runID: runID))
    #expect(!NativeCapabilityAITools.consumeExactApproval(for: call, runID: runID))
    #expect(NativeCapabilityAITools.recordExactApproval(approval, call: call, runID: runID))
    #expect(NativeCapabilityAITools.consumeExactApproval(for: call, runID: runID))
    #expect(!NativeCapabilityAITools.consumeExactApproval(for: call, runID: runID))
}

#if DEBUG
@Test @MainActor func delegatedNativeApprovalRejectsChangedExpiredAndDirectoryGrant() async throws {
    let conversation = AIConversation()
    let model = AIChatViewModel(
        store: AIConversationStore(fixtures: [conversation]),
        credentials: AIChatCredentialStore(configuration: .fixture),
        nativeToolStore: LimaAIToolStore(fixtures: ["audio_get_output"]),
        transport: FixtureAITransport.standard
    )
    let runID = UUID()
    model.setExecutionRunForTesting(AIExecutionRun(
        id: runID, conversationID: conversation.id,
        userMessageID: UUID(), assistantMessageID: UUID(),
        providerConfigurationSnapshot: AIExecutionProviderConfigurationSnapshot(
            providerID: "fixture", modelID: "fixture", reasoningEffort: "none"
        ),
        toolConfigurationSnapshot: AIExecutionToolConfigurationSnapshot(
            localToolIDs: ["audio_get_output"]
        )
    ))
    func request(_ id: String) -> Task<Bool, Never> {
        let call = AIOutputItem(
            phase: .completed, apiType: "function_call", callID: id,
            name: "audio_get_output", arguments: "{}"
        )
        return Task { await model.requestSubagentApprovalForTesting(call, conversationID: conversation.id) }
    }
    func awaitVisible(_ id: String) async throws -> AIToolApprovalRequest {
        for _ in 0..<100 {
            if let approval = model.pendingApproval, approval.localCallID == id { return approval }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeCapabilityAuthorizationError.approvalRequired
    }

    let changed = request("native-child-changed")
    var changedApproval = try await awaitVisible("native-child-changed")
    changedApproval.arguments = "{\"uid\":\"changed\"}"
    model.replacePendingApprovalForTesting(changedApproval)
    model.resolvePendingApproval(allow: true)
    #expect(!(await changed.value))

    let expired = request("native-child-expired")
    var expiredApproval = try await awaitVisible("native-child-expired")
    expiredApproval.createdAt = Date().addingTimeInterval(-121)
    model.replacePendingApprovalForTesting(expiredApproval)
    model.resolvePendingApproval(allow: true)
    #expect(!(await expired.value))

    let directory = request("native-child-directory")
    _ = try await awaitVisible("native-child-directory")
    model.resolvePendingApproval(allow: true, grantDirectory: true)
    #expect(!(await directory.value))

    let exact = request("native-child-exact")
    _ = try await awaitVisible("native-child-exact")
    model.resolvePendingApproval(allow: true)
    #expect(await exact.value)
    let approvedCall = AIOutputItem(
        phase: .completed, apiType: "function_call", callID: "native-child-exact",
        name: "audio_get_output", arguments: "{}"
    )
    #expect(NativeCapabilityAITools.consumeExactApproval(for: approvedCall, runID: runID))
    #expect(!NativeCapabilityAITools.consumeExactApproval(for: approvedCall, runID: runID))
}
#endif
