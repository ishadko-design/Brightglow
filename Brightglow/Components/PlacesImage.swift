import SwiftUI

/// Loads a remote image while sending the app's iOS bundle-ID header.
///
/// Google Places photo URLs carry the API key in the query string, and that key
/// is restricted to this app's bundle ID — so a plain `AsyncImage` request is
/// rejected with 403. This loader attaches `X-Ios-Bundle-Identifier`, following
/// the 302 redirect to the actual image. Non-restricted URLs (e.g. the mock
/// `lh3.googleusercontent.com` photos) load fine too; the header is just ignored.

/// Small in-memory cache of decoded images, keyed by URL. Avoids re-fetching and
/// re-decoding the same photo when paging through a card or when a card that was
/// already on screen becomes the top card again.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }

    /// Fetch + decode into the cache if not already present. Used to warm a
    /// card's photos so paging/swiping never shows a gray placeholder.
    @discardableResult
    func prefetch(_ url: URL) async -> UIImage? {
        if let hit = image(for: url) { return hit }
        guard let img = await Self.download(url) else { return nil }
        insert(img, for: url)
        return img
    }

    static func download(_ url: URL) async -> UIImage? {
        var req = URLRequest(url: url)
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let img = UIImage(data: data) else { return nil }
        return img
    }
}

/// Loads a Places photo. Holds the previous image while a new URL loads (no gray
/// flash on change) and reads decoded images straight from `ImageCache`.
struct PlacesImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        // Seed synchronously from the cache so a warm photo renders on the first
        // frame — even when the view is re-created (e.g. crossfade .id changes).
        _image = State(initialValue: url.flatMap { ImageCache.shared.image(for: $0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        // Cache hit → swap instantly, no placeholder, no network.
        if let cached = ImageCache.shared.image(for: url) {
            if image !== cached { image = cached }
            return
        }
        // Miss → keep showing the current image until the new one decodes, then swap.
        guard let img = await ImageCache.shared.prefetch(url) else { return }
        image = img
    }
}
