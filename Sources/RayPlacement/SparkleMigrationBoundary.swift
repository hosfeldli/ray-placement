import Foundation
import Sparkle

/// Sparkle is the stable production updater. The legacy signed-custom backend
/// remains available only as an explicit emergency/testing override.
enum UpdateBackend: String {
    case legacy = "signed-custom"
    case sparkle
}

@MainActor
final class SparkleUpdateService {
    static let shared = SparkleUpdateService()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }
}

/// Migration seam for Sparkle 2. EdDSA appcast verification is the production
/// trust anchor; legacy certificate pinning is opt-in only.
@MainActor
final class SparkleMigrationBoundary {
    static let appcastURL = URL(string: "https://github.com/hosfeldli/ray-placement/releases/latest/download/appcast.xml")!

    static let activeBackend: UpdateBackend = {
        guard let requested = ProcessInfo.processInfo.environment["LIMA_UPDATE_BACKEND"]?.lowercased() else {
            return .sparkle
        }
        // Accept the historical spelling for emergency scripts, but never
        // silently fall back to the certificate-pinned updater.
        if requested == "legacy" || requested == "signed-custom" { return .legacy }
        return UpdateBackend(rawValue: requested) ?? .sparkle
    }()

    static var sparklePackageAvailable: Bool { true }
}
