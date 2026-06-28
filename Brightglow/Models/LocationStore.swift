import CoreLocation
import Combine
import MapKit

/// App-wide location state for the main screen's "no permissions" flow.
///
/// A user can get a location three ways:
///   1. tap the locate button → request permission + a GPS fix, reverse-geocoded
///      to a city label;
///   2. type a ZIP or city into the header field → forward-geocoded to a coordinate;
///   3. (implicitly) if permission was already granted in a past session.
///
/// `coordinate` is the resolved location used to search for contractors.
@MainActor
final class LocationStore: NSObject, ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var label: String?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isResolving = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var pendingFix: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    var hasLocation: Bool { coordinate != nil }
    /// True once the user has actively denied location — fall back to manual entry.
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Tap-to-locate: prompt for permission if needed, take a fix, reverse-geocode.
    func useCurrentLocation() {
        Task {
            isResolving = true
            defer { isResolving = false }
            guard let coord = await requestFix() else { return }
            coordinate = coord
            label = await reverseGeocode(coord)
        }
    }

    /// Manual entry: turn a typed ZIP / city into a coordinate + tidy label.
    ///
    /// Uses `MKLocalSearch` first — it resolves bare place names ("Kyiv",
    /// "Paris") worldwide far more reliably than `CLGeocoder.geocodeAddressString`,
    /// which frequently returns nothing for a single-word city. Falls back to the
    /// geocoder (good for raw ZIPs) if the search finds nothing.
    func setManualLocation(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        Task {
            isResolving = true
            defer { isResolving = false }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = [.address, .pointOfInterest]
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                coordinate = item.placemark.coordinate
                label = item.placemark.locality ?? item.name ?? query
                return
            }

            // Fallback: ZIP / address string via the geocoder.
            if let place = try? await geocoder.geocodeAddressString(query).first,
               let loc = place.location {
                coordinate = loc.coordinate
                label = place.locality ?? place.postalCode ?? query
            }
        }
    }

    // MARK: - Permission + fix

    private func requestFix() async -> CLLocationCoordinate2D? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return await fix()
        case .notDetermined:
            return await withCheckedContinuation { cont in
                pendingFix = cont
                manager.requestWhenInUseAuthorization()   // system prompt
            }
        default:
            return nil
        }
    }

    private func fix() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            pendingFix = cont
            manager.requestLocation()
        }
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) async -> String? {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let mark = try? await geocoder.reverseGeocodeLocation(loc).first
        return mark?.locality ?? mark?.administrativeArea
    }

    private func resume(_ coord: CLLocationCoordinate2D?) {
        pendingFix?.resume(returning: coord)
        pendingFix = nil
    }
}

extension LocationStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorization = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()              // resolves the pending fix
            case .denied, .restricted:
                resume(nil)
            default:
                break
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
