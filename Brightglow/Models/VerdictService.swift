import Foundation

/// Cross-user photo-screening verdicts via the Supabase `verdicts` Edge Function.
/// The first user to screen a place uploads which photos are work shots; every
/// other user (any device) reuses that verdict and skips screening — so a place's
/// pool is downloaded for classification at most once across all users.
///
/// All calls are best-effort: any failure returns empty / no-ops, so the app
/// simply falls back to on-device screening (and the local [[ScreeningStore]]).
enum VerdictService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// `enriched` = the kept photos carry rich vision tags (from `phototags`),
    /// not just generic on-device labels. When false, the client re-enriches this
    /// verdict on first load so photo ordering can match specific queries.
    struct Verdict { let kept: [ScreenedPhoto]; let scanned: Int; let enriched: Bool }

    private static func vertical(_ allowVehicles: Bool) -> String { allowVehicles ? "auto" : "home" }

    private static func request(_ body: [String: Any]) -> URLRequest? {
        guard let url = URL(string: "https://\(ref).supabase.co/functions/v1/verdicts") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Batch-fetch shared verdicts for the given place ids.
    static func fetch(ids: [String], allowVehicles: Bool) async -> [String: Verdict] {
        guard isConfigured, !ids.isEmpty,
              let req = request(["op": "get", "vertical": vertical(allowVehicles), "ids": ids]),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(FetchResponse.self, from: data)
        else { return [:] }
        return decoded.verdicts.mapValues {
            Verdict(kept: $0.kept, scanned: $0.scanned, enriched: $0.enriched ?? false)
        }
    }

    /// Upload a verdict after on-device screening (fire-and-forget). `enriched`
    /// marks whether `kept` carries rich `phototags` tags, so other users skip
    /// re-enriching it.
    static func upload(id: String, allowVehicles: Bool, kept: [ScreenedPhoto],
                       scanned: Int, enriched: Bool = false) {
        let keptJSON = kept.map { ["url": $0.url, "labels": $0.labels] as [String: Any] }
        guard isConfigured,
              let req = request(["op": "put", "vertical": vertical(allowVehicles),
                                 "id": id, "kept": keptJSON, "scanned": scanned,
                                 "enriched": enriched])
        else { return }
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    private struct FetchResponse: Decodable { let verdicts: [String: Entry] }
    private struct Entry: Decodable { let kept: [ScreenedPhoto]; let scanned: Int; let enriched: Bool? }
}
