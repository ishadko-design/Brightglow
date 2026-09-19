import Foundation

/// Fetches meaning fingerprints (embeddings) for photos and the search query.
///
/// Two data sources, one call: the Supabase `photo-embeddings` Edge Function
/// returns fingerprints for photo URLs (computing them on demand via the
/// brightglow-embed Cloudflare Worker when missing) AND embeds the query text
/// in the same round trip.
///
/// Why this exists: `PhotoFilter.order` ranks by word overlap between the query
/// and photo labels. Words collide — "wall" matches both an interior drywall
/// shot and an exterior siding shot — so an interior photo can lead an exterior
/// paint search. Fingerprints capture the whole scene's meaning, and cosine
/// similarity ranks exterior scenes above interior ones for an exterior query.
///
/// Best-effort like PhotoTagService: any failure returns the input unchanged
/// (photos without fingerprints, nil query fingerprint), and `PhotoFilter.order`
/// falls back to word matching. Results never depend on this call.
enum PhotoEmbeddingService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// In-memory cache: the query text is identical for every business in a
    /// search, so embed it once and reuse. Cleared when the query changes.
    private static var queryCache: (text: String, embedding: [Float])?

    /// Returns `photos` with `embedding` filled in where the service had one,
    /// plus the query's fingerprint (cached per query text). Either may be
    /// missing on failure — the caller passes what it got to
    /// `PhotoFilter.order(queryEmbedding:)`, which falls back to word matching
    /// for anything without a fingerprint.
    static func enrich(_ photos: [ScreenedPhoto], query: String) async
        -> (photos: [ScreenedPhoto], queryEmbedding: [Float]?)
    {
        guard isConfigured,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/photo-embeddings")
        else { return (photos, nil) }

        // Reuse the cached query fingerprint when the query hasn't changed.
        let cachedQuery: [Float]? =
            (queryCache?.text == query) ? queryCache?.embedding : nil

        // Skip the network call when there's nothing to do.
        let needsPhotos = photos.contains { $0.embedding == nil }
        if !needsPhotos, let qe = cachedQuery {
            return (photos, qe)
        }

        var body: [String: Any] = [:]
        if needsPhotos {
            body["urls"] = photos.map(\.url)
            // Fresh tags help the server compute fingerprints for photos it
            // hasn't seen (avoids a read-after-write race with phototags).
            var tags: [String: [String]] = [:]
            for p in photos where !p.labels.isEmpty { tags[p.url] = p.labels }
            if !tags.isEmpty { body["tags"] = tags }
        }
        if cachedQuery == nil, !query.isEmpty { body["query"] = query }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return (photos, cachedQuery) }

        if let qe = decoded.queryEmbedding {
            queryCache = (query, qe)
        }
        let enriched = photos.map { photo -> ScreenedPhoto in
            guard photo.embedding == nil,
                  let vec = decoded.embeddings[photo.url] else { return photo }
            var p = photo
            p.embedding = vec
            return p
        }
        return (enriched, decoded.queryEmbedding ?? cachedQuery)
    }

    /// Clears the cached query fingerprint (call when the search query changes).
    static func invalidateQueryCache() { queryCache = nil }

    private struct Response: Decodable {
        let embeddings: [String: [Float]]
        let queryEmbedding: [Float]?
    }
}
