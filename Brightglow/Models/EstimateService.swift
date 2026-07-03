import Foundation
import CoreLocation

/// Local price estimates for a job — real data only, never a synthesized guess.
///
/// The only source is `PricingService` (SF DBI permits + retail material
/// pricing, where covered). A prior "real dollar amounts mentioned in nearby
/// reviews" tier was removed 2026-07-03: `priceMentions` regex-extracts any
/// dollar figure anywhere in review text with no way to tell a job-cost
/// mention from a tip, a discount, or a comparison to a competitor's quote —
/// it produced implausible, noisy ranges (e.g. "$35-700" for a faucet
/// replacement) that looked authoritative but weren't, which is worse than
/// showing nothing. If `estimate` returns nil, callers show a "Coming soon"
/// placeholder (with a real business count alongside it) instead — see
/// `priceComingSoonText`.
enum EstimateService {

    /// A locally-aware price range for a job, or nil if no real data backs one.
    static func estimate(job: String, locality: String) async -> PriceTier? {
        await PricingService.estimate(job: job, locality: locality)
    }

    /// Reverse-geocode a coordinate to a "City, ST" locality string.
    static func locality(for coord: CLLocationCoordinate2D) async -> String {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return "" }
        return [mark.locality, mark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
