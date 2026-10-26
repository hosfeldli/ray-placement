import ApplicationServices
import Testing
@testable import RayPlacement

@Test func mailAutomationPermissionClassifiesOSStatusWithoutSendingEvents() {
    #expect(MailAutomationPermissionProbe.classify(noErr) == .granted)
    #expect(MailAutomationPermissionProbe.classify(OSStatus(errAEEventWouldRequireUserConsent)) == .needsConsent)
    #expect(MailAutomationPermissionProbe.classify(OSStatus(errAEEventNotPermitted)) == .denied)
    #expect(MailAutomationPermissionProbe.classify(OSStatus(procNotFound)) == .mailNotRunning)
    #expect(MailAutomationPermissionProbe.classify(-1) == .unavailable)
}

@Test func mailAutomationPermissionDoesNotProbeWithoutRunningMailPID() {
    #expect(MailAutomationPermissionProbe.status(forPID: nil) == .mailNotRunning)
    #expect(MailAutomationPermissionProbe.status(forPID: 0) == .mailNotRunning)
}
