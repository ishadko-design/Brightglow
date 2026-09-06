import Foundation

/// Client-side dedupe + result cache for price estimates, and the seam that lets
/// an estimate START EARLY (on capture) so it's ready by the time the results
/// header asks for it.
///
/// Why it matters: the `pricing` Edge Function may run a bounded web search
/// (grounded estimate) that takes a few seconds on a cold job+metro. That search
/// is cached server-side per job-type + metro, and the server keeps warming that
/// cache in the background even when a request times out. So the winning move is
/// to fire the estimate the moment we have a photo read + a location — while the
/// user is still in the clarify chat — which:
///   • warms the server's classification and grounded caches, and
///   • (when the later results call uses the same inputs) is deduped to the same
///     in-flight task or served straight from this cache — no second wait.
///
/// Best-effort like everything in the pricing path: a failure just returns nil and
/// the caller shows the "coming soon" placeholder.
actor EstimateCache {
    static let shared = EstimateCache()

    /// Completed estimates by request signature (this session).
    private var results: [String: PriceTier] = [:]
    /// In-flight requests, so a prefetch and the later results call share one
    /// network round trip instead of racing two.
    private var inFlight: [String: Task<PriceTier?, Never>] = [:]

    // ── Cross-launch persistence ────────────────────────────────────────────────
    // Estimates change slowly (the server caches the grounded number for 14 days),
    // so a result seen in one launch is reused in the next — a repeat job then
    // shows its price with no network at all. Stored in UserDefaults as a small,
    // TTL-pruned, size-capped map.
    private let store = UserDefaults.standard
    private let storeKey = "estimateCache.v1"
    private let ttl: TimeInterval = 7 * 24 * 60 * 60   // 7 days
    private let maxEntries = 200
    private var loadedFromDisk = false

    private struct Persisted: Codable { let tier: PriceTier; let at: TimeInterval }

    /// Fold the persisted (unexpired) entries into `results` on first use.
    private func loadIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = store.data(forKey: storeKey),
              let dict = try? JSONDecoder().decode([String: Persisted].self, from: data)
        else { return }
        let now = Date().timeIntervalSince1970
        for (k, p) in dict where now - p.at < ttl && results[k] == nil {
            results[k] = p.tier
        }
    }

    /// Write-through one result, pruning expired entries and capping the store.
    private func persist(_ key: String, _ tier: PriceTier) {
        var dict: [String: Persisted] = {
            guard let data = store.data(forKey: storeKey),
                  let d = try? JSONDecoder().decode([String: Persisted].self, from: data)
            else { return [:] }
            return d
        }()
        let now = Date().timeIntervalSince1970
        dict = dict.filter { now - $0.value.at < ttl }
        dict[key] = Persisted(tier: tier, at: now)
        if dict.count > maxEntries {
            let newest = dict.sorted { $0.value.at > $1.value.at }.prefix(maxEntries)
            dict = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(dict) { store.set(data, forKey: storeKey) }
    }

    private func key(_ category: String, _ description: String,
                     _ zip: String?, _ vehicle: VehicleFilter?, _ fast: Bool) -> String {
        [category, description, zip ?? "", vehicle?.rawValue ?? "", fast ? "fast" : "full"]
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
    }

    /// The cached result if we have one; otherwise the value of the in-flight task
    /// (started here or by an earlier prefetch); otherwise a fresh call. `fast` is
    /// part of the signature so the phase-1 (formula) and phase-2 (grounded) calls
    /// are cached separately.
    func estimate(category: String, description: String,
                  zip: String?, vehicle: VehicleFilter?, fast: Bool = false) async -> PriceTier? {
        loadIfNeeded()
        let k = key(category, description, zip, vehicle, fast)
        if let cached = results[k] { return cached }
        if let task = inFlight[k] { return await task.value }

        let task = Task<PriceTier?, Never> {
            await PricingService.estimate(category: category, description: description,
                                          zip: zip, vehicle: vehicle, fast: fast)
        }
        inFlight[k] = task
        let value = await task.value
        inFlight[k] = nil
        if let value {
            results[k] = value
            persist(k, value)
        }
        return value
    }

    /// Fire-and-forget warm-up. Call this as soon as a job is guessable (on
    /// capture, and again once the clarify chat refines it) so the slow parts are
    /// already done — or in flight — when the results header requests the estimate.
    nonisolated func prefetch(category: String, description: String,
                              zip: String?, vehicle: VehicleFilter?, fast: Bool = false) {
        Task { _ = await estimate(category: category, description: description,
                                  zip: zip, vehicle: vehicle, fast: fast) }
    }
}
