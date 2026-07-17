import SwiftUI
import Combine

/// Carries a `brightglow://chat` deep link into the UI. A business tapping
/// "Open in the app" (from the lead email or the web chat page) lands here;
/// `MainScreen` consumes the flag to open the inbox. The flag persists across
/// the login screen, so a not-yet-signed-in business is taken to their
/// conversations right after they authenticate.
@MainActor
final class ChatRouter: ObservableObject {
    @Published var openInboxRequested = false

    /// When true, the inbox should jump straight into the most recently active
    /// thread — a bare `brightglow://chat` / `/chat` link means "take me to my
    /// last conversation," not just the list. Set for path-less chat links.
    @Published var openLatestRequested = false

    /// A specific thread to open, keyed by its lead `public_id`
    /// (`brightglow://chat/<publicId>` or `/chat/<publicId>`). The lead email's
    /// "reply in the app" link targets the exact conversation this way.
    @Published var targetPublicID: String? = nil

    /// Returns true if it consumed the url (a chat deep link), so the caller
    /// knows not to also hand it to the auth handlers. Accepts both the custom
    /// scheme (brightglow://chat) and the https Universal Link the lead email
    /// uses (https://brightglow.co/chat…), so tapping the email opens the app.
    /// An optional trailing path segment names a specific thread; without one we
    /// open the latest.
    func handle(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()

        let isCustomScheme = scheme == "brightglow" && host == "chat"
        let isUniversalLink = scheme == "https"
            && (host == "brightglow.co" || host == "www.brightglow.co")
            && url.path.lowercased().hasPrefix("/chat")

        guard isCustomScheme || isUniversalLink else { return false }

        // Pull an optional thread id out of the path:
        //   brightglow://chat/<publicId>          → host "chat", path "/<publicId>"
        //   https://brightglow.co/chat/<publicId> → path "/chat/<publicId>"
        let segments = url.pathComponents.filter { $0 != "/" }
        let publicID = isCustomScheme ? segments.first
                                      : (segments.count >= 2 ? segments[1] : nil)

        openInboxRequested = true
        if let publicID, !publicID.isEmpty {
            targetPublicID = publicID       // open this exact thread
            openLatestRequested = false
        } else {
            openLatestRequested = true      // bare /chat → open the last thread
        }
        return true
    }
}
