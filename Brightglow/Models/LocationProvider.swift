import CoreLocation
import Combine

/// One-shot location helper: requests when-in-use permission (if needed) and
/// resolves the user's current coordinate. Returns nil when access is denied
/// or a fix can't be obtained, so callers can fall back gracefully.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Current coordinate, prompting for permission on first use.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return await requestFix()
        case .notDetermined:
            // The same continuation is carried through: auth callback → fix.
            return await withCheckedContinuation { cont in
                pending = cont
                manager.requestWhenInUseAuthorization()
            }
        default:
            return nil
        }
    }

    private func requestFix() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            pending = cont
            manager.requestLocation()
        }
    }

    private func resume(_ coord: CLLocationCoordinate2D?) {
        pending?.resume(returning: coord)
        pending = nil
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()          // resolves the pending continuation
            case .denied, .restricted:
                resume(nil)
            default:
                break                              // still .notDetermined — keep waiting
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in resume(locations.first?.coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in resume(nil) }
    }
}
