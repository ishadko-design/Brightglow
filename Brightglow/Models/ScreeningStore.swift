import Foundation

/// Persists the photo-screening verdict per place across launches, so a repeat
/// visit doesn't re-download a business's photos just to re-run the on-device
/// classifier. Keyed by place id + vertical (a place screened for Auto & moto
/// keeps vehicle shots, so its verdict differs from the Home pass).
///
/// Stores the *kept display URLs* and how many source photos were scanned, so the
/// list strip can resume lazy screening from where it left off. This only spares
/// the screening downloads on a single device — cross-user reuse needs the
/// backend. Entries expire after 30 days to stay within Places caching terms.
final class ScreeningStore: @unchecked Sendable {
    static let shared = ScreeningStore()

    struct Entry: Codable {
        let kept: [ScreenedPhoto]; let scanned: Int; let at: Double
        /// Whether `kept` carries rich `phototags` labels (vs generic on-device
        /// ones). Decodes to false for entries written before this field existed,
        /// so they get enriched once on next view.
        let enriched: Bool

        init(kept: [ScreenedPhoto], scanned: Int, at: Double, enriched: Bool) {
            self.kept = kept; self.scanned = scanned; self.at = at; self.enriched = enriched
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kept = try c.decode([ScreenedPhoto].self, forKey: .kept)
            scanned = try c.decode(Int.self, forKey: .scanned)
            at = try c.decode(Double.self, forKey: .at)
            enriched = try c.decodeIfPresent(Bool.self, forKey: .enriched) ?? false
        }
    }

    private let ttl: TimeInterval = 30 * 24 * 3600
    private let lock = NSLock()
    private var map: [String: Entry] = [:]
    private let fileURL: URL
    private let io = DispatchQueue(label: "screeningstore.io", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("screening_verdicts.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            map = decoded
        }
    }

    private func key(_ id: String, allowVehicles: Bool) -> String {
        (allowVehicles ? "v:" : "h:") + id
    }

    /// A still-valid verdict for this place, or nil (never screened / expired).
    func get(_ id: String, allowVehicles: Bool) -> (kept: [ScreenedPhoto], scanned: Int, enriched: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[key(id, allowVehicles: allowVehicles)],
              Date().timeIntervalSince1970 - e.at < ttl else { return nil }
        return (e.kept, e.scanned, e.enriched)
    }

    func save(_ id: String, allowVehicles: Bool, kept: [ScreenedPhoto], scanned: Int, enriched: Bool = false) {
        lock.lock()
        map[key(id, allowVehicles: allowVehicles)] =
            Entry(kept: kept, scanned: scanned, at: Date().timeIntervalSince1970, enriched: enriched)
        lock.unlock()
        scheduleWrite()
    }

    /// Coalesce frequent saves (one per screened business while scrolling) into a
    /// single debounced disk write.
    private func scheduleWrite() {
        pendingWrite?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingWrite = item
        io.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func writeNow() {
        lock.lock(); let snapshot = map; lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
