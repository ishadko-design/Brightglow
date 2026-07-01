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

    struct Verdict { let kept: [String]; let scanned: Int }

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
        return decoded.verdicts.mapValues { Verdict(kept: $0.kept, scanned: $0.scanned) }
    }

    /// Upload a verdict after on-device screening (fire-and-forget).
    static func upload(id: String, allowVehicles: Bool, kept: [String], scanned: Int) {
        guard isConfigured,
              let req = request(["op": "put", "vertical": vertical(allowVehicles),
                                 "id": id, "kept": kept, "scanned": scanned])
        else { return }
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    private struct FetchResponse: Decodable { let verdicts: [String: Entry] }
    private struct Entry: Decodable { let kept: [String]; let scanned: Int }
}
