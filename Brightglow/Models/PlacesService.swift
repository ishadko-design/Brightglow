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

    private static let searchRadius: Double = 40_000   // metres (~25 mi)
    private static let responseTimes: [ResponseTime] = [.fast, .normal, .slow]

    // MARK: - Public API

    /// Contractors of a single trade near the user.
    static func fetch(category: Category, near coord: CLLocationCoordinate2D,
                      maxResults: Int = 12) async -> [Contractor] {
        await fetch(textQuery: category.searchQuery, category: category,
                    near: coord, maxResults: maxResults)
    }

    /// Contractors for a free-form query (e.g. "leaky tap") near the user.
    /// The matched trade drives price tiers and the category tag.
    static func fetch(searchText query: String, near coord: CLLocationCoordinate2D,
                      maxResults: Int = 12) async -> [Contractor] {
        let category = Category.matching(query: query).first ?? .plumbing
        return await fetch(textQuery: "\(query) contractor", category: category,
                           near: coord, maxResults: maxResults)
    }

    // MARK: - Core request

    private static func fetch(textQuery: String, category: Category,
                              near coord: CLLocationCoordinate2D,
                              maxResults: Int) async -> [Contractor] {
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchText") else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        // The API key is restricted to this app's iOS bundle ID. A raw URLSession
        // request must send it explicitly, or Google returns 403 and we'd silently
        // fall back to mock data.
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        req.setValue(
            "places.id,places.displayName,places.rating,places.userRatingCount,"
            + "places.formattedAddress,places.nationalPhoneNumber,places.photos,"
            + "places.businessStatus,places.reviews",
            forHTTPHeaderField: "X-Goog-FieldMask")

        let body: [String: Any] = [
            "textQuery": textQuery,
            "maxResultCount": maxResults,
            "locationBias": ["circle": [
                "center": ["latitude": coord.latitude, "longitude": coord.longitude],
                "radius": searchRadius,
            ]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(PlacesResponse.self, from: data)
        else { return [] }

        return decoded.places.enumerated().compactMap { idx, place in
            contractor(from: place, index: idx, category: category)
        }
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
        var usable = allPhotos.filter { min($0.widthPx ?? 0, $0.heightPx ?? 0) >= 600 }
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
    private static func reviews(from raw: [PlaceReview]?) -> [Review] {
        (raw ?? []).compactMap { r in
            let body = (r.text?.text ?? r.originalText?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return Review(
                author: r.authorAttribution?.displayName ?? "Google user",
                authorPhotoURL: r.authorAttribution?.photoUri,
                rating: r.rating ?? 5,
                text: body,
                relativeTime: r.relativePublishTimeDescription ?? ""
            )
        }
    }

    /// Places photo-media URL. `skipHttpRedirect` is omitted so the endpoint
    /// 302-redirects straight to the image — `AsyncImage` follows it, no extra call.
    private static func photoURL(for photoName: String) -> String {
        "https://places.googleapis.com/v1/\(photoName)/media?maxWidthPx=1200&key=\(apiKey)"
    }

    /// Best-effort locality from a formatted address
    /// ("123 Main St, San Francisco, CA 94102, USA" → "San Francisco").
    private static func city(from address: String) -> String {
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return parts.first ?? "" }
        return parts[parts.count - 3]
    }
}

// MARK: - Places JSON

private struct PlacesResponse: Decodable {
    let places: [Place]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        places = (try? c.decode([Place].self, forKey: .places)) ?? []
    }
    enum CodingKeys: String, CodingKey { case places }
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
}

private struct LocalizedText: Decodable { let text: String }
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
