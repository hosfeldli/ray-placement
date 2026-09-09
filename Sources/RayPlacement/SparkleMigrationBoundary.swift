import Foundation

#if LIMA_SPARKLE_MIGRATION
import Sparkle
#endif

/// Migration seam for Sparkle 2. The signed Lima updater remains the active
/// backend until the Sparkle rehearsal has passed an N→N+1 install test.
@MainActor
final class SparkleMigrationBoundary {
    static let activeBackend = "signed-custom"
    static let appcastURL = URL(string: "https://github.com/hosfeldli/ray-placement/releases/latest/download/appcast.xml")!

    static var sparklePackageAvailable: Bool {
        #if LIMA_SPARKLE_MIGRATION
        return true
        #else
        return false
        #endif
    }

    #if LIMA_SPARKLE_MIGRATION
    /// Constructed only by a future cutover experiment. Keeping this type in a
    /// separate boundary prevents Sparkle state from changing the active updater.
    static func migrationPackageMarker() -> String { String(describing: SPUStandardUpdaterController.self) }
    #endif
}
