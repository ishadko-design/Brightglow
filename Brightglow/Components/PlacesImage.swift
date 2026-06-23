import SwiftUI

/// Loads a remote image while sending the app's iOS bundle-ID header.
///
/// Google Places photo URLs carry the API key in the query string, and that key
/// is restricted to this app's bundle ID — so a plain `AsyncImage` request is
/// rejected with 403. This loader attaches `X-Ios-Bundle-Identifier`, following
/// the 302 redirect to the actual image. Non-restricted URLs (e.g. the mock
/// `lh3.googleusercontent.com` photos) load fine too; the header is just ignored.
struct PlacesImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        var req = URLRequest(url: url)
        if let bundleID = Bundle.main.bundleIdentifier {
            req.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let img = UIImage(data: data) else { return }
        image = img
    }
}
