import Foundation

/// A single truthful Browser status derived only from recorded tool events
/// and the selected tab's explicit pause state.
struct BrowserWorkspaceActivitySummary: Equatable {
    let label: String
    let symbol: String
    let isBlocked: Bool

    static func resolve(activity: BrowserAIActivity?, isPaused: Bool) -> Self? {
        if isPaused {
            return Self(label: "Paused · AI access on this tab", symbol: "pause.circle", isBlocked: false)
        }
        guard let activity else { return nil }
        switch activity.state {
        case .working:
            let observationPrefixes = ["Reading", "Inspecting", "Finding", "Scanning", "Waiting"]
            let phase = observationPrefixes.contains(where: { activity.title.hasPrefix($0) })
                ? "Observing" : "Acting"
            return Self(label: "\(phase) · \(activity.title)", symbol: "circle.dotted", isBlocked: false)
        case .completed:
            // A returned tool call is not proof that a remote transaction succeeded.
            return Self(label: "Returned · \(activity.title)", symbol: "checkmark.circle", isBlocked: false)
        case .failed:
            return Self(label: "Blocked · \(activity.title)", symbol: "exclamationmark.circle", isBlocked: true)
        }
    }
}
