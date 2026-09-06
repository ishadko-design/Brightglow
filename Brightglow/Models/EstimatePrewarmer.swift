import Foundation
import CoreLocation

/// Optionally pre-warms the grounded (web-searched) estimate for a few common jobs
/// in the user's metro, so those specific searches show a price instantly.
///
/// Gated by `FeatureFlags.prewarmPopularEstimates` (off by default) — see that flag
/// for the cost/benefit. Runs at most once per metro (zip3) per app session.
enum EstimatePrewarmer {
    /// A deliberately short, high-frequency list — each entry that isn't already
    /// cached costs one paid web search, so the list length is the spend per metro.
    private static let popularJobs: [(category: String, description: String)] = [
        ("Plumbing",        "water heater replacement"),
        ("Electrical",      "electrical panel upgrade"),
        ("HVAC",            "furnace repair"),
        ("Painting",        "interior painting"),
        ("Roofing",         "roof replacement"),
        ("Windows & Doors", "sliding glass door replacement"),
    ]

    private static var warmedZips = Set<String>()
    private static let lock = NSLock()

    /// Warm the popular jobs for the metro at `coord`. No-op when the flag is off or
    /// the metro was already warmed this session. Best-effort and fully detached —
    /// never blocks anything the user is doing.
    static func warmPopular(near coord: CLLocationCoordinate2D) {
        guard FeatureFlags.prewarmPopularEstimates else { return }
        Task.detached(priority: .background) {
            let (_, zip) = await EstimateService.geocode(for: coord)
            guard let zip, zip.count >= 3 else { return }
            let zip3 = String(zip.prefix(3))

            lock.lock()
            let already = warmedZips.contains(zip3)
            if !already { warmedZips.insert(zip3) }
            lock.unlock()
            guard !already else { return }

            for job in popularJobs {
                EstimateCache.shared.prefetch(category: job.category, description: job.description,
                                              zip: zip, vehicle: nil, fast: false)
            }
        }
    }
}
