import UIKit

/// Enriches screened work photos with rich, query-independent semantic tags from
/// the Supabase `phototags` Edge Function (a vision model), unioned into each
/// [[ScreenedPhoto]]'s `labels`.
///
/// Why this exists: on-device Apple Vision (see [[PhotoFilter]]) can only emit
/// generic scene labels — its 1300-class taxonomy has no token for "bumper", a
/// windshield, or a car make — so `PhotoFilter.order` can never rank photos for
/// an auto search like "bumper for Mazda" and they stay in Google's raw order.
/// The vision model names the part / material / subject (and the brand when a
/// badge is legible), so the SAME on-device ranker then surfaces the right shot.
///
/// Cost is bounded and shared: callers enrich only on the first on-device screen
/// of a place, then persist the enriched labels to [[ScreeningStore]] and upload
/// them via [[VerdictService]], so a place's pool is tagged at most once across
/// all users. The images sent are the screening renditions the app ALREADY
/// downloaded and cached, so tagging adds no Google Places Photo requests.
///
/// Best-effort like the other services: any failure returns `nil`, so the caller
/// keeps the on-device labels and can retry on a later visit — results never
/// depend on this call.
enum PhotoTagService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// Tag at most this many photos per place — the pool Places returns is ≤10 and
    /// the strip/gallery only need a handful ranked well.
    private static let maxPhotos = 12
    /// Re-encode each cached screening image to a small JPEG for tagging: a bumper
    /// or a countertop is unmistakable well below screening resolution, and small
    /// images keep both the upload and the vision-token cost down.
    private static let tagImageMaxSide: CGFloat = 448
    private static let tagImageQuality: CGFloat = 0.5

    /// Returns `photos` with their `labels` unioned with the model's tags, or
    /// `nil` when the service didn't run (not configured, no cached image,
    /// network/model error) — a nil return means "not enriched", so the caller
    /// keeps the on-device order and may retry on a later visit; a non-nil return
    /// (even with unchanged labels) means the model ran and the verdict can be
    /// marked enriched. Never re-downloads: it reads the screening rendition from
    /// [[ImageCache]] (a cache hit from screening) and skips any uncached photo.
    static func enrich(_ photos: [ScreenedPhoto], allowVehicles: Bool) async -> [ScreenedPhoto]? {
        guard isConfigured, !photos.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/phototags")
        else { return nil }

        // Build the payload from already-cached screening images (same rendition
        // the screener downloaded → cache hit, no new Places request).
        var items: [[String: String]] = []
        for photo in photos.prefix(maxPhotos) {
            let screenURL = PlacesService.photoURL(photo.url, width: PlacesService.listPhotoWidth)
            guard let u = URL(string: screenURL),
                  let img = await ImageCache.download(u),
                  let b64 = base64JPEG(img) else { continue }
            items.append(["url": photo.url, "image": b64])
        }
        guard !items.isEmpty else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "vertical": allowVehicles ? "auto" : "home",
            "photos": items,
        ])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }   // couldn't reach / parse → not enriched; caller retries later

        // Reached the model — union any tags in. A place the model had nothing
        // for keeps its labels but still counts as enriched (a non-nil return),
        // so we don't re-tag it every visit.
        return photos.map { photo in
            guard let tags = decoded.tags[photo.url], !tags.isEmpty else { return photo }
            let merged = Array(Set(photo.labels + tags.map { $0.lowercased() }))
            return ScreenedPhoto(url: photo.url, labels: merged)
        }
    }

    /// Downscale (aspect-preserving) and JPEG-encode to base64 for the payload.
    private static func base64JPEG(_ image: UIImage) -> String? {
        let side = max(image.size.width, image.size.height)
        let scale = side > tagImageMaxSide ? tagImageMaxSide / side : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return small.jpegData(compressionQuality: tagImageQuality)?.base64EncodedString()
    }

    private struct Response: Decodable { let tags: [String: [String]] }
}
