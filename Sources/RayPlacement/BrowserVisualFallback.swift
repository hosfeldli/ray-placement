import Foundation

/// A point found by the native Browser against a specific private screenshot.
/// The opaque hit ID is process-local and unusable after a fresh read, user
/// interaction, page mutation, tab close, or Browser authority change.
struct BrowserVisualHit: Codable, Sendable {
    let id: UUID
    let captureID: UUID
    let tabID: UUID
    let label: String
    let role: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let semanticTargetID: String?
    let pageIdentity: BrowserPageIdentity

    var userSummary: String {
        let host = URLComponents(string: pageIdentity.url)?.host ?? "this site"
        let name = label.isEmpty ? "a visual target" : "“\(label)”"
        return "Review visual click on \(name) at \(host). This action uses a point on the current Browser screenshot and may have consequences that cannot be classified from page semantics."
    }
}

struct BrowserVisualHitPayload: Decodable {
    let label: String
    let role: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let semanticTargetID: String?
}
