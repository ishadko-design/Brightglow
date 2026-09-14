import Foundation
import Supabase

/// OTA-tunable ranking configuration for the contractor list.
///
/// Row id=1 of the `ranking_config` table (public read). The app refreshes it
/// in the background on every search, caches it in UserDefaults, and falls
/// back to `fallback` when offline or unconfigured — so factor weights,
/// small-job pool widening, licensed-trade rules, and draft behavior retune
/// from the Supabase dashboard with no App Store release.
struct RankingConfig: Codable {
    struct Weights: Codable {
        /// Job-specific proof: reviews naming the searched work.
        var reviewMatch: Double = 0.45
        /// Job-specific proof: screened work photos of it.
        var photoMatch: Double = 0.30
        /// Right-sized business for the job's price (handyman for small jobs).
        var sizeFit: Double = 0.25
        /// Upstream Places order (proximity, rating quality, prominence).
        var upstream: Double = 0.20
    }
    struct SmallJob: Codable {
        /// Kill switch for the whole small-job path.
        var enabled: Bool = true
        /// How many handymen from the supplement query merge into the pool.
        var supplementCount: Int = 4
    }
    /// Per-trade licensed-work rule, keyed by `Category.rawValue.lowercased()`.
    /// `always` = the trade never favors handymen (electrical: life safety).
    /// `signals` = job-description phrases that keep the job with licensed pros
    /// (plumbing: gas; hvac: furnace/refrigerant/…); without them a small job
    /// is handyman-appropriate.
    struct LicensedRule: Codable {
        var always: Bool? = nil
        var signals: [String]? = nil
    }
    /// OTA-tunable draft behavior for the quote-request screen.
    struct Draft: Codable {
        /// Keep the edited request text after a successful send, so the user
        /// can send the same text to other contractors without re-editing.
        var persistOnSend: Bool = true
        /// Only restore the draft when the clarify transcript matches the one
        /// it was saved for. Prevents a stale draft from leaking into a new
        /// request (new clarify session).
        var scopeToTranscript: Bool = true
    }

    var version: Int = 1
    var weights: Weights = Weights()
    var smallJob: SmallJob = SmallJob()
    var draft: Draft = Draft()
    var licensed: [String: LicensedRule] = [
        "electrical": LicensedRule(always: true),
        "plumbing": LicensedRule(signals: ["gas"]),
        "hvac": LicensedRule(signals: ["furnace", "refrigerant", "freon",
                                       "compressor", "condenser", "heat pump", "gas"]),
    ]

    static let fallback = RankingConfig()
}

/// Fetches and caches the ranking config. `current` is always safe to read —
/// bundled fallback → cached → freshly fetched, in that order. Refreshing never
/// blocks a search: the list screen fires it in the background and new weights
/// apply to scoring live.
enum RankingConfigStore {
    private static let cacheKey = "ranking_config_json"
    private static let rowID = 1

    /// Read on the main thread (SwiftUI view code and `@MainActor` loaders);
    /// writes are dispatched to the main actor in `refresh()`.
    static var current: RankingConfig = loadCache() ?? .fallback

    /// Pulls the latest config; silently keeps the current one on any failure
    /// (offline, unconfigured table, schema drift).
    static func refresh() async {
        guard let fetched = await fetchRemote() else { return }
        await MainActor.run {
            current = fetched
            saveCache(fetched)
        }
    }

    // MARK: - private

    private struct Row: Codable { var config: RankingConfig }

    private static func fetchRemote() async -> RankingConfig? {
        do {
            let rows: [Row] = try await supabase
                .from("ranking_config")
                .select("config")
                .eq("id", value: rowID)
                .execute()
                .value
            return rows.first?.config
        } catch {
            return nil
        }
    }

    private static func loadCache() -> RankingConfig? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(RankingConfig.self, from: data)
    }

    private static func saveCache(_ config: RankingConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
