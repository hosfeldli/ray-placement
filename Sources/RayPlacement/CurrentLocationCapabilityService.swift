import CoreLocation
import Foundation
import RayPlacementCore

/// One-shot foreground location request. Coordinates are returned to the
/// reviewed AI call, never cached or written to Lima's local stores.
@MainActor
final class CurrentLocationCapabilityService: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = CurrentLocationCapabilityService()

    enum Failure: LocalizedError {
        case unavailable
        case permissionDenied
        case alreadyPending
        case timedOut
        case inaccurate

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Location Services are unavailable on this Mac."
            case .permissionDenied: return "Location access was not granted for Lima. Enable it in System Settings and retry."
            case .alreadyPending: return "A current-location request is already pending."
            case .timedOut: return "The Mac did not provide a current location in time."
            case .inaccurate: return "The Mac did not provide a recent, usable location."
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var requestID: UUID?
    private var timeout: Timer?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> JSONValue {
        try Task.checkCancellation()
        guard CLLocationManager.locationServicesEnabled() else { throw Failure.unavailable }
        guard continuation == nil else { throw Failure.alreadyPending }
        let requestID = UUID()
        let location = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
                self.continuation = continuation
                self.requestID = requestID
                timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard self?.requestID == requestID else { return }
                        self?.finish(.failure(Failure.timedOut))
                    }
                }
                switch manager.authorizationStatus {
                case .authorizedAlways, .authorizedWhenInUse:
                    manager.requestLocation()
                case .notDetermined:
                    manager.requestWhenInUseAuthorization()
                case .denied, .restricted:
                    finish(.failure(Failure.permissionDenied))
                @unknown default:
                    finish(.failure(Failure.permissionDenied))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == requestID else { return }
                self?.manager.stopUpdatingLocation()
                self?.finish(.failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
        let coordinate = location.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude),
              (-180...180).contains(coordinate.longitude),
              location.horizontalAccuracy.isFinite,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 10_000,
              abs(location.timestamp.timeIntervalSinceNow) <= 120 else {
            throw Failure.inaccurate
        }
        return .object([
            "latitude": .number(coordinate.latitude),
            "longitude": .number(coordinate.longitude),
            "horizontal_accuracy_m": .number(location.horizontalAccuracy),
            "observed_at": .string(ISO8601DateFormatter().string(from: location.timestamp)),
            "source": .string("macOS Location Services")
        ])
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(Failure.permissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(.failure(Failure.permissionDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(Failure.inaccurate))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.invalidate()
        timeout = nil
        guard let continuation else { return }
        self.continuation = nil
        requestID = nil
        continuation.resume(with: result)
    }
}
