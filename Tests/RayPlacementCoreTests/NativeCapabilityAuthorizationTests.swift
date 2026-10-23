import Foundation
import Testing
@testable import RayPlacementCore

private func nativeCall(
    operation: NativeCapabilityOperation = .screenshotCapture,
    origin: NativeCapabilityOrigin = .ai(runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, toolCallID: "call-1"),
    arguments: JSONValue = .object(["mode": .string("display"), "display_id": .string("main")])
) -> NativeCapabilityCall {
    NativeCapabilityCall(origin: origin, operation: operation, arguments: arguments)
}

@Test func nativeCapabilityApprovalBindsExactCallAndIsOneShot() async throws {
    let authority = NativeCapabilityAuthorizer()
    let call = nativeCall()
    let id = try await authority.recordExplicitApproval(for: call)

    let changedArguments = nativeCall(arguments: .object(["mode": .string("window"), "display_id": .string("main")]))
    do {
        try await authority.authorize(changedArguments, approvalID: id, osPermissionGranted: true)
        Issue.record("Changed arguments must not use the approved call")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .approvalRequired)
    }
    do {
        try await authority.authorize(call, approvalID: id, osPermissionGranted: true)
        Issue.record("A mismatched call must consume its grant")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .approvalRequired)
    }

    let exactID = try await authority.recordExplicitApproval(for: call)
    try await authority.authorize(call, approvalID: exactID, osPermissionGranted: true)
    do {
        try await authority.authorize(call, approvalID: exactID, osPermissionGranted: true)
        Issue.record("An approval may authorize one call only")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .approvalRequired)
    }
}

@Test func nativeCapabilityApprovalBindsOriginAndOperationAndExpires() async throws {
    let authority = NativeCapabilityAuthorizer(lifetime: 5)
    let now = Date(timeIntervalSince1970: 1000)
    let call = nativeCall()
    let id = try await authority.recordExplicitApproval(for: call, now: now)
    let changedOperation = nativeCall(operation: .screenshotList)
    do {
        try await authority.authorize(changedOperation, approvalID: id, osPermissionGranted: true, now: now)
        Issue.record("Changed operations must fail")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .approvalRequired)
    }

    let secondID = try await authority.recordExplicitApproval(for: call, now: now)
    let changedOrigin = nativeCall(origin: .ai(runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, toolCallID: "call-1"))
    do {
        try await authority.authorize(changedOrigin, approvalID: secondID, osPermissionGranted: true, now: now)
        Issue.record("Changed origin must fail")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .approvalRequired)
    }

    let expiredID = try await authority.recordExplicitApproval(for: call, now: now)
    do {
        try await authority.authorize(call, approvalID: expiredID, osPermissionGranted: true, now: now.addingTimeInterval(6))
        Issue.record("Expired approval must fail")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .approvalExpired)
    }
}

@Test func nativeCapabilityExtensionRequiresLiveApprovedCapabilityAndOSAccess() async throws {
    let authority = NativeCapabilityAuthorizer()
    let call = nativeCall(
        operation: .calendarCreateEvent,
        origin: .extensionCommand(extensionID: "pack.one", manifestHash: "hash-1", commandID: "create"),
        arguments: .object(["title": .string("Review")])
    )
    let snapshot = NativeExtensionAuthoritySnapshot(
        extensionID: "pack.one", manifestHash: "hash-1", approved: true,
        capabilities: [.calendar]
    )
    let id = try await authority.recordExplicitApproval(for: call)
    do {
        try await authority.authorize(call, approvalID: id, installedExtension: .init(
            extensionID: "pack.one", manifestHash: "hash-2", approved: true, capabilities: [.calendar]
        ), osPermissionGranted: true)
        Issue.record("Changed installed manifest must fail")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .extensionNotApproved)
    }

    let deniedID = try await authority.recordExplicitApproval(for: call)
    do {
        try await authority.authorize(call, approvalID: deniedID, installedExtension: snapshot, osPermissionGranted: false)
        Issue.record("OS access must still be required")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .osPermissionDenied)
    }

    let acceptedID = try await authority.recordExplicitApproval(for: call)
    try await authority.authorize(call, approvalID: acceptedID, installedExtension: snapshot, osPermissionGranted: true)
}

@Test func nativeCapabilityUIStillRequiresPermissionAndValidArguments() async throws {
    let authority = NativeCapabilityAuthorizer()
    let call = nativeCall(origin: .userInterface(surfaceID: "screenshot-studio"))
    do {
        try await authority.authorize(call, osPermissionGranted: false)
        Issue.record("A user interface request cannot bypass OS access")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .osPermissionDenied)
    }
    try await authority.authorize(call, osPermissionGranted: true)

    let invalid = nativeCall(arguments: .array([]))
    do {
        try await authority.authorize(invalid, osPermissionGranted: true)
        Issue.record("Non-object arguments must fail")
    } catch {
        #expect(error as? NativeCapabilityAuthorizationError == .invalidCall)
    }
}
