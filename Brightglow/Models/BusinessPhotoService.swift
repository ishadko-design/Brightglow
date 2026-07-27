import Foundation

/// Free, zero-consent photo enrichment via the Supabase `business-photos` Edge
/// Function. Given a business's own website (Google Places' `websiteUri`), it
/// returns photos the site shows of its work — the highest-yield *free* source
/// beyond Google Places' 10-photo, no-cache cap.
///
/// The Edge Function caches per place_id and is shared across users, so the
/// external website fetch happens once per business, not per gallery-open — the
/// client just calls this one endpoint. Best-effort like ClarifyService /
/// LicenseService: any failure returns [] and the gallery falls back to Places.
enum BusinessPhotoService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// Work-photo URLs discovered on the business's own website, or [] when there
    /// are none / no website / the service is unavailable.
    static func fetch(placeId: String, website: String?) async -> [String] {
        let site = website?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isConfigured, !placeId.isEmpty, !site.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/business-photos")
        else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["place_id": placeId, "website": site])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return [] }
        // The scraper returns whatever scheme the site links, which is very often
        // plain http://. iOS App Transport Security blocks cleartext image loads
        // outright (it won't even follow the site's http→https 301), so an http://
        // photo can be neither screened nor displayed — it survives screening
        // fail-open and then renders as a black tile at the top of the gallery.
        // Upgrade to https up front: essentially every site that links http serves
        // the same asset over https, and this keeps the URL consistent across the
        // cache key, screening, and display.
        return decoded.photos.map { $0.url.hasPrefix("http://")
            ? "https://" + $0.url.dropFirst("http://".count)
            : $0.url }
    }

    private struct Response: Decodable { let photos: [Photo] }
    private struct Photo: Decodable { let url: String }
}
