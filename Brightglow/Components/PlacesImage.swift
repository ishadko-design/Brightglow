import SwiftUI
import CryptoKit

/// Loads a remote image while sending the app's iOS bundle-ID header.
///
/// Google Places photo URLs carry the API key in the query string, and that key
/// is restricted to this app's bundle ID — so a plain `AsyncImage` request is
/// rejected with 403. This loader attaches `X-Ios-Bundle-Identifier`, following
/// the 302 redirect to the actual image. Non-restricted URLs (e.g. the mock
/// `lh3.googleusercontent.com` photos) load fine too; the header is just ignored.

/// Two-level cache of decoded images, keyed by URL: an in-memory `NSCache` for
/// the current session, backed by a persistent disk store under Caches. The disk
/// layer is what makes a *repeat launch on the same device* free — once a Places
/// photo has been fetched, it re-displays from disk instead of re-billing Google.
/// (Cross-user reuse needs the backend; this only helps a single device.)
final class ImageCache {
    static let shared = ImageCache()

    private let mem = NSCache<NSURL, UIImage>()
    private let dir: URL
    // Concurrent + user-initiated: reads/writes touch distinct files (hashed
    // names) so they're independent. A serial queue here would funnel every
    // image in the app through one lane — the list's dozens of reads would block
    // the gallery's first-photo read, making the gallery look like it won't open.
    private let io = DispatchQueue(label: "imagecache.io", qos: .userInitiated, attributes: .concurrent)
    /// Cap the on-disk cache so it can't grow without bound; oldest files evicted.
    private let maxDiskBytes = 250 * 1024 * 1024

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("PlacesImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        io.async { [weak self] in self?.trimIfNeeded() }
    }

    /// Synchronous, memory-only — used to seed the first frame without touching
    /// disk (a miss here just falls through to the async `prefetch`).
    func image(for url: URL) -> UIImage? { mem.object(forKey: url as NSURL) }
    func insert(_ image: UIImage, for url: URL) { mem.setObject(image, forKey: url as NSURL) }

    /// Memory → disk → network. Decoded bytes persist to disk on a network fetch,
    /// so the same photo on a later launch costs nothing.
    @discardableResult
    func prefetch(_ url: URL) async -> UIImage? {
        if let hit = mem.object(forKey: url as NSURL) { return hit }
        if let img = await readDisk(url) {
            mem.setObject(img, forKey: url as NSURL)
            return img
        }
        guard let (data, img) = await Self.fetch(url) else { return nil }
        mem.setObject(img, forKey: url as NSURL)
        let file = fileURL(for: url)
        io.async { try? data.write(to: file, options: .atomic) }
        return img
    }

    /// Name kept for the photo screener; same memory→disk→network path, so the
    /// screening downloads also seed the disk cache.
    static func download(_ url: URL) async -> UIImage? { await shared.prefetch(url) }

    // MARK: - Disk

    private func fileURL(for url: URL) -> URL { dir.appendingPathComponent(Self.key(url)) }

    /// Stable filename from the URL (String.hashValue is randomized per launch and
    /// unusable for a persistent key, so hash the bytes instead).
    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readDisk(_ url: URL) async -> UIImage? {
        let file = fileURL(for: url)
        return await withCheckedContinuation { cont in
            io.async {
                guard let data = try? Data(contentsOf: file), let img = UIImage(data: data) else {
                    cont.resume(returning: nil); return
                }
                // Bump the mod date so the LRU trim treats it as recently used.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                cont.resume(returning: img)
            }
        }
    }

    /// Best-effort LRU eviction when the cache exceeds its byte budget.
    private func trimIfNeeded() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for f in files {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let size = v?.fileSize ?? 0
            entries.append((f, size, v?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > maxDiskBytes else { return }
        for e in entries.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: e.url)
            total -= e.size
            if total <= maxDiskBytes { break }
        }
    }

    static func fetch(_ url: URL) async -> (Data, UIImage)? {
        var req = URLRequest(url: url)
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let img = UIImage(data: data) else { return nil }
        return (data, img)
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
