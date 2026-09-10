import Foundation
import Sparkle

/// The updater backend remains legacy by default while Sparkle is rehearsed.
/// Set `LIMA_UPDATE_BACKEND=sparkle` only for an explicit local bridge test.
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

/// Migration seam for Sparkle 2. The signed Lima updater remains the active
/// backend until a real installed-app N→N+1 rehearsal has passed.
@MainActor
final class SparkleMigrationBoundary {
    static let appcastURL = URL(string: "https://github.com/hosfeldli/ray-placement/releases/latest/download/appcast.xml")!

    static let activeBackend: UpdateBackend = {
        guard let requested = ProcessInfo.processInfo.environment["LIMA_UPDATE_BACKEND"],
              let backend = UpdateBackend(rawValue: requested.lowercased()) else {
            return .legacy
        }
        return backend
    }()

    static var sparklePackageAvailable: Bool { true }
}
