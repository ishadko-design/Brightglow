import Foundation
import CoreLocation
import MapKit

/// Local price estimates for a job — real data only, never a synthesized guess.
///
/// The only source is `PricingService` (nationwide regional cost data,
/// cross-checked against SF permits where they overlap). A prior "real
/// dollar amounts mentioned in nearby reviews" tier was removed 2026-07-03:
/// `priceMentions` regex-extracts any dollar figure anywhere in review text
/// with no way to tell a job-cost mention from a tip, a discount, or a
/// comparison to a competitor's quote — it produced implausible, noisy
/// ranges (e.g. "$35-700" for a faucet replacement) that looked
/// authoritative but weren't, which is worse than showing nothing. If
/// `estimate` returns nil, callers show a "Coming soon" placeholder (with a
/// real business count alongside it) instead — see `priceComingSoonText`.
enum EstimateService {

    /// A locally-aware price range for a job, or nil if no real data backs one.
    ///
    /// Goes through [[EstimateCache]] so a value already fetched (or prefetched on
    /// capture — see `ContractorLoader.prefetchEstimate`) is returned immediately,
    /// and a still-in-flight prefetch is awaited rather than duplicated.
    static func estimate(category: String, description: String, zip: String?,
                         vehicle: VehicleFilter? = nil, fast: Bool = false) async -> PriceTier? {
        await EstimateCache.shared.estimate(category: category, description: description,
                                            zip: zip, vehicle: vehicle, fast: fast)
    }

    /// Reverse-geocode a coordinate to a "City, ST" locality string plus its
    /// postal code — the zip resolves EstimationPro's regional multiplier
    /// and gates the SF-permit cross-check server-side.
    ///
    /// Uses MapKit's `MKReverseGeocodingRequest` (`CLGeocoder` is deprecated in
    /// iOS 26). `MKAddressRepresentations` has no structured postal-code field,
    /// so the US ZIP is parsed from the full postal address — the LAST 5-digit
    /// group, so a 5-digit street number can't shadow it. (Pricing data is
    /// US-only, so the US ZIP shape is the only one that matters here.)
    static func geocode(for coord: CLLocationCoordinate2D) async -> (locality: String, zip: String?) {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: loc),
                  let item = try? await request.mapItems.first else { return ("", nil) }
            // "Cupertino, CA" — same shape the old locality + admin-area pair made.
            let locality = item.addressRepresentations?.cityWithContext ?? ""
            let zip = item.address?.fullAddress.matches(of: /\b\d{5}\b/).last.map { String($0.0) }
            return (locality, zip)
        } else {
            // iOS 18–25: CLGeocoder exposes a structured postal code directly.
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return ("", nil) }
            let locality: String
            if let city = placemark.locality, let state = placemark.administrativeArea {
                locality = "\(city), \(state)"
            } else {
                locality = placemark.locality ?? placemark.administrativeArea ?? ""
            }
            return (locality, placemark.postalCode)
        }
    }
}
