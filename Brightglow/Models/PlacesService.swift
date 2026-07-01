import Foundation
import CoreLocation

/// Live contractor lookup via the Google Places API (Text Search), biased to
/// the user's location. Mirrors the field mapping of `scripts/seed_contractors.py`
/// but runs at request time so results reflect the user's actual area.
///
/// ⚠️ Prototype: the API key ships in the binary. Before production, move this
/// call behind a backend proxy that holds the key and forwards the query.
enum PlacesService {

    /// Reads `PLACES_API_KEY` from Info.plist (injected from the untracked
    /// Secrets.xcconfig at build time). Empty when not configured.
    private static let apiKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "PLACES_API_KEY") as? String) ?? ""

    /// Supabase backend (project ref + publishable key), injected the same way as
    /// the Places key. When both are present, searches route through the backend
    /// proxy so the Google key stays server-side; empty → direct Google calls.
    private static let supabaseRef: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let supabaseAnonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static var useBackend: Bool { !supabaseRef.isEmpty && !supabaseAnonKey.isEmpty }

    private static let searchRadius: Double = 40_000   // metres (~25 mi)
    private static let responseTimes: [ResponseTime] = [.fast, .normal, .slow]

    // MARK: - Public API

    /// One page of results plus the token to fetch the next page (`nil` when
    /// there are no more results).
    struct Page { let contractors: [Contractor]; let nextPageToken: String? }

    /// Contractors of a single trade near the user (first page only).
    static func fetch(category: Category, near coord: CLLocationCoordinate2D,
                      maxResults: Int = 20) async -> [Contractor] {
        await fetchPage(category: category, near: coord, pageSize: maxResults).contractors
    }

    /// Contractors for a free-form query (e.g. "leaky tap") near the user.
    /// The matched trade drives price tiers and the category tag.
    static func fetch(searchText query: String, near coord: CLLocationCoordinate2D,
                      maxResults: Int = 20) async -> [Contractor] {
        await fetchPage(searchText: query, near: coord, pageSize: maxResults).contractors
    }

    /// A page of trade results plus the next-page token.
    static func fetchPage(category: Category, near coord: CLLocationCoordinate2D,
                          pageSize: Int = 20, pageToken: String? = nil) async -> Page {
        await search(textQuery: category.searchQuery, category: category,
                     near: coord, pageSize: pageSize, pageToken: pageToken)
    }

    /// A page of free-form results plus the next-page token.
    static func fetchPage(searchText query: String, near coord: CLLocationCoordinate2D,
                          pageSize: Int = 20, pageToken: String? = nil) async -> Page {
        let category = Category.matching(query: query).first ?? .plumbing
        return await search(textQuery: "\(query) contractor", category: category,
                            near: coord, pageSize: pageSize, pageToken: pageToken)
    }

    // MARK: - Core request

    private static func search(textQuery: String, category: Category,
                               near coord: CLLocationCoordinate2D,
                               pageSize: Int, pageToken: String?) async -> Page {
        let empty = Page(contractors: [], nextPageToken: nil)

        // Serve repeat first-page searches from a short-lived cache so re-entering
        // a category or flipping the Auto⇄Moto filter back doesn't re-bill a Text
        // Search. Only first pages are cached (continuation tokens are one-shot).
        // ~5km location buckets, matching the backend cache key so both layers
        // dedupe the same nearby searches.
        let latBucket = (coord.latitude / 0.05).rounded() * 0.05
        let lngBucket = (coord.longitude / 0.05).rounded() * 0.05
        let cacheKey: String? = pageToken == nil
            ? "\(textQuery)|\(String(format: "%.2f", latBucket))|\(String(format: "%.2f", lngBucket))|\(pageSize)"
            : nil
        if let cacheKey, let cached = SearchCache.shared.page(for: cacheKey) { return cached }

        // Fetch the raw Places JSON — via the backend proxy when configured,
        // otherwise (or on failure) straight from Google.
        guard let data = await searchJSON(textQuery: textQuery, near: coord,
                                          pageSize: pageSize, pageToken: pageToken),
              let decoded = try? JSONDecoder().decode(PlacesResponse.self, from: data)
        else { return empty }

        // `locationBias` only *ranks* by proximity — it can still return far-away
        // businesses (e.g. an Indian shop for a Kyiv search). Hard-filter by actual
        // distance so results truly belong to the searched area.
        let center = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let maxDistance = searchRadius * 1.5
        let contractors = decoded.places.enumerated().compactMap { idx, place -> Contractor? in
            if let loc = place.location {
                let d = center.distance(from: CLLocation(latitude: loc.latitude, longitude: loc.longitude))
                guard d <= maxDistance else { return nil }
            }
            return contractor(from: place, index: idx, category: category)
        }
        let page = Page(contractors: contractors, nextPageToken: decoded.nextPageToken)
        if let cacheKey { SearchCache.shared.save(page, for: cacheKey) }
        return page
    }

    // MARK: - Raw request (backend proxy → Google fallback)

    /// Raw Places `searchText` JSON. Tries the Supabase backend proxy first (which
    /// holds the API key server-side); falls back to a direct Google call if the
    /// backend is disabled or unreachable, so the app keeps working (kill-switch).
    private static func searchJSON(textQuery: String, near coord: CLLocationCoordinate2D,
                                   pageSize: Int, pageToken: String?) async -> Data? {
        if useBackend,
           let data = await backendSearchJSON(textQuery: textQuery, near: coord,
                                              pageSize: pageSize, pageToken: pageToken) {
            return data
        }
        return await googleSearchJSON(textQuery: textQuery, near: coord,
                                      pageSize: pageSize, pageToken: pageToken)
    }

    /// Search via the Supabase Edge Function, which forwards to Google with the
    /// server-held key. Returns Google's raw response shape (decodable as
    /// `PlacesResponse`), or nil to trigger the direct-Google fallback.
    private static func backendSearchJSON(textQuery: String, near coord: CLLocationCoordinate2D,
                                          pageSize: Int, pageToken: String?) async -> Data? {
        guard let url = URL(string: "https://\(supabaseRef).supabase.co/functions/v1/search")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "textQuery": textQuery,
            "latitude": coord.latitude,
            "longitude": coord.longitude,
            "pageSize": pageSize,
        ]
        if let pageToken { body["pageToken"] = pageToken }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Direct Google Places call — the fallback path and the pre-backend default.
    private static func googleSearchJSON(textQuery: String, near coord: CLLocationCoordinate2D,
                                         pageSize: Int, pageToken: String?) async -> Data? {
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchText")
        else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // The API key is restricted to this app's iOS bundle ID. A raw URLSession
        // request must send it explicitly, or Google returns 403.
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        // `nextPageToken` must be in the field mask for pagination to come back.
        req.setValue(
            "places.id,places.displayName,places.rating,places.userRatingCount,"
            + "places.formattedAddress,places.nationalPhoneNumber,places.photos,"
            + "places.businessStatus,places.reviews,places.location,nextPageToken",
            forHTTPHeaderField: "X-Goog-FieldMask")
        var body: [String: Any] = [
            "textQuery": textQuery,
            "maxResultCount": pageSize,
            "locationBias": ["circle": [
                "center": ["latitude": coord.latitude, "longitude": coord.longitude],
                "radius": searchRadius,
            ]],
        ]
        if let pageToken { body["pageToken"] = pageToken }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Mapping

    private static func contractor(from place: Place, index: Int, category: Category) -> Contractor? {
        guard let name = place.displayName?.text else { return nil }

        // Every card must have an image — skip placeless results.
        // Cheap pre-filter: drop low-resolution source photos (small originals
        // are usually logos, screenshots, or poor uploads) before downloading.
        // Fall back to the unfiltered set so a card is never left blank.
        // Pull the full candidate pool (Places returns up to 10) so the on-device
        // screen has plenty to choose from after rejecting weak images.
        let allPhotos = place.photos ?? []
        var usable = allPhotos.filter { min($0.widthPx ?? 0, $0.heightPx ?? 0) >= 800 }
        if usable.isEmpty { usable = allPhotos }
        let photos = usable.prefix(10).map { photoURL(for: $0.name) }
        guard !photos.isEmpty else { return nil }

        return Contractor(
            id: place.id,
            name: name,
            category: [category],
            city: city(from: place.formattedAddress ?? ""),
            rating: place.rating ?? 4.0,
            reviewCount: place.userRatingCount ?? 0,
            responseTime: responseTimes[index % responseTimes.count],
            yearsActive: 5 + (index % 15),
            photos: photos,
            priceTiers: category.priceTiers,
            phone: place.nationalPhoneNumber,
            licenseNumber: nil,
            isVerified: (place.businessStatus ?? "OPERATIONAL") == "OPERATIONAL",
            reviews: reviews(from: place.reviews)
        )
    }

    /// Map Places reviews → our model, keeping those with real written text.
    ///
    /// `text` is Google's translation into the request locale; `originalText` is
    /// the author's original language. We show the translation by default but keep
    /// the original (and its language name) so the UI can offer a "See original"
    /// toggle — translation is the default, reverting to original is the choice.
    private static func reviews(from raw: [PlaceReview]?) -> [Review] {
        (raw ?? []).compactMap { r in
            let display = (r.text?.text ?? r.originalText?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty else { return nil }

            // Offer the original only when it actually differs from what we show.
            let original = r.originalText?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let origLang = r.originalText?.languageCode
            let hasDistinctOriginal = original.map { !$0.isEmpty && $0 != display } ?? false

            return Review(
                author: r.authorAttribution?.displayName ?? "Google user",
                authorPhotoURL: r.authorAttribution?.photoUri,
                rating: r.rating ?? 5,
                text: display,
                relativeTime: r.relativePublishTimeDescription ?? "",
                originalText: hasDistinctOriginal ? original : nil,
                originalLanguageName: hasDistinctOriginal ? languageName(origLang) : nil
            )
        }
    }

    /// "uk" → "Ukrainian" (localized to the device). nil/unknown → nil.
    private static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized
    }

    /// Display rendition for the full-screen gallery (crisp on 3x screens).
    static let fullPhotoWidth = 1600
    /// Small rendition for list strips + on-device screening (≈3x of a 112pt
    /// thumbnail). Screening and the list reuse the SAME rendition so a strip
    /// photo costs one Places Photo request, not two.
    static let listPhotoWidth = 512

    /// Places photo-media URL. `skipHttpRedirect` is omitted so the endpoint
    /// 302-redirects straight to the image — `AsyncImage` follows it, no extra call.
    private static func photoURL(for photoName: String) -> String {
        // Stored at full width; the list re-renders smaller via `photoURL(_:width:)`.
        "https://places.googleapis.com/v1/\(photoName)/media?maxWidthPx=\(fullPhotoWidth)&key=\(apiKey)"
    }

    /// Re-render an existing photo URL at a different width. Works on Places media
    /// URLs (swaps `maxWidthPx`); any other URL (e.g. seeded mock CDN URLs) is
    /// returned unchanged.
    static func photoURL(_ url: String, width: Int) -> String {
        guard let range = url.range(of: #"maxWidthPx=\d+"#, options: .regularExpression) else { return url }
        return url.replacingCharacters(in: range, with: "maxWidthPx=\(width)")
    }

    /// Best-effort locality from a formatted address
    /// ("123 Main St, San Francisco, CA 94102, USA" → "San Francisco").
    private static func city(from address: String) -> String {
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return parts.first ?? "" }
        return parts[parts.count - 3]
    }
}

// MARK: - Search cache

/// Disk-persisted cache of first-page search results, keyed by query + coarse
/// location. Spares a Text Search when the user re-enters a category, flips the
/// Auto⇄Moto filter back, or reopens the app within a day — so a cold launch
/// doesn't re-bill the search. 24h TTL keeps within Places caching terms (place
/// data ≤30 days). Cross-user reuse still needs the backend.
private final class SearchCache: @unchecked Sendable {
    static let shared = SearchCache()

    private struct Entry: Codable {
        let contractors: [Contractor]
        let nextPageToken: String?
        let at: Double
    }

    private let ttl: TimeInterval = 24 * 3600
    private let lock = NSLock()
    private var store: [String: Entry] = [:]
    private let fileURL: URL
    private let io = DispatchQueue(label: "searchcache.io", qos: .utility)
    private var pendingWrite: DispatchWorkItem?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("search_results.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            store = decoded
        }
    }

    func page(for key: String) -> PlacesService.Page? {
        lock.lock(); defer { lock.unlock() }
        guard let e = store[key], Date().timeIntervalSince1970 - e.at < ttl else { return nil }
        return PlacesService.Page(contractors: e.contractors, nextPageToken: e.nextPageToken)
    }

    func save(_ page: PlacesService.Page, for key: String) {
        lock.lock()
        store[key] = Entry(contractors: page.contractors, nextPageToken: page.nextPageToken,
                           at: Date().timeIntervalSince1970)
        lock.unlock()
        scheduleWrite()
    }

    /// Coalesce writes into a single debounced disk flush.
    private func scheduleWrite() {
        pendingWrite?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingWrite = item
        io.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func writeNow() {
        lock.lock(); let snapshot = store; lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Places JSON

private struct PlacesResponse: Decodable {
    let places: [Place]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = (try? c.decode([Place].self, forKey: .places)) ?? []
        nextPageToken = try? c.decode(String.self, forKey: .nextPageToken)
    }
    enum CodingKeys: String, CodingKey { case places, nextPageToken }
}

private struct Place: Decodable {
    let id: String
    let displayName: LocalizedText?
    let rating: Double?
    let userRatingCount: Int?
    let formattedAddress: String?
    let nationalPhoneNumber: String?
    let photos: [Photo]?
    let businessStatus: String?
    let reviews: [PlaceReview]?
    let location: LatLng?
}

private struct LatLng: Decodable {
    let latitude: Double
    let longitude: Double
}

private struct LocalizedText: Decodable {
    let text: String
    let languageCode: String?
}
private struct Photo: Decodable {
    let name: String
    let widthPx: Int?
    let heightPx: Int?
}

private struct PlaceReview: Decodable {
    let rating: Int?
    let text: LocalizedText?
    let originalText: LocalizedText?
    let relativePublishTimeDescription: String?
    let authorAttribution: AuthorAttribution?
}

private struct AuthorAttribution: Decodable {
    let displayName: String?
    let photoUri: String?
}
