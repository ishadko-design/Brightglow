import Foundation

/// Hosted contractor logos via the Supabase `logos` Edge Function.
///
/// The function resolves a business's logo ONCE (from its website), normalizes
/// it to a tiny PNG in the public `business-logos` bucket, and caches the result
/// on the `business_enrichment` row — so this call is cheap and cross-user
/// shared: a place resolved by any user is reused everywhere. See
/// `supabase/functions/logos/index.ts`.
///
/// **A missing result means "no hosted logo" (no website, or none found), never
/// an error.** The call is best-effort — any failure returns empty — and the UI
/// draws a name monogram for every business not in the result, so a logo simply
/// appears when one exists and nothing is blocked when one doesn't.
enum LogoService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// Public logo URLs keyed by contractor id, for businesses that have one.
    /// Only contractors with a website are looked up (the rest can't resolve a
    /// logo); those simply don't appear in the result.
    static func fetch(for contractors: [Contractor]) async -> [String: URL] {
        await fetch(items: contractors.map { (placeId: $0.id, website: $0.website) })
    }

    /// Logo URLs keyed by place_id, for a list of businesses identified by their
    /// Places id (+ optional website). A place already resolved (logo cached in
    /// `business_enrichment`) returns from cache with or without a website; an
    /// uncached place resolves only when a website is supplied. Businesses with
    /// no logo simply don't appear in the result. Used by the chat to render a
    /// conversation's business avatar from the id stored on the lead.
    static func fetch(items entries: [(placeId: String, website: String?)]) async -> [String: URL] {
        let items: [[String: String]] = entries.compactMap { e in
            let id = e.placeId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            var item = ["place_id": id]
            if let site = e.website?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty {
                item["website"] = site
            }
            return item
        }

        guard isConfigured, !items.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/logos")
        else { return [:] }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["op": "get", "items": items])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(FetchResponse.self, from: data)
        else { return [:] }

        var out: [String: URL] = [:]
        for (id, urlString) in decoded.logos {
            if let u = URL(string: urlString) { out[id] = u }
        }
        return out
    }

    private struct FetchResponse: Decodable { let logos: [String: String] }
}
