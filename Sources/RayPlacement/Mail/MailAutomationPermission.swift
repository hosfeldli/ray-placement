import ApplicationServices
import Foundation

/// A snapshot of the current process's Automation access to a running Mail app.
/// Checking never launches Mail, sends an Apple Event, or requests consent.
enum MailAutomationPermission: Equatable, Sendable {
    case notChecked
    case mailNotRunning
    case granted
    case needsConsent
    case denied
    case unavailable

    var label: String {
        switch self {
        case .notChecked: return "Not checked"
        case .mailNotRunning: return "Mail is not running"
        case .granted: return "Allowed"
        case .needsConsent: return "Permission required"
        case .denied: return "Denied"
        case .unavailable: return "Could not determine"
        }
    }
}

enum MailAutomationPermissionProbe {
    /// Pass a PID found on the main actor. The OS query must run off the main
    /// thread because it can take arbitrarily long, even without a prompt.
    static func status(forPID rawPID: pid_t?) -> MailAutomationPermission {
        guard var processID = rawPID, processID > 0 else {
            return .mailNotRunning
        }
        var target = AEDesc()
        let creationStatus = AECreateDesc(
            DescType(typeKernelProcessID),
            &processID,
            MemoryLayout<pid_t>.size,
            &target
        )
        guard creationStatus == noErr else { return .unavailable }
        defer { AEDisposeDesc(&target) }
        return classify(AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, false
        ))
    }

    static func classify(_ status: OSStatus) -> MailAutomationPermission {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .mailNotRunning
        default: return .unavailable
        }
    }
}
