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

    /// Returns true if it consumed the url (a chat deep link), so the caller
    /// knows not to also hand it to the auth handlers. Accepts both the custom
    /// scheme (brightglow://chat) and the https Universal Link the lead email
    /// uses (https://brightglow.co/chat…), so tapping the email opens the app.
    func handle(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()

        let isCustomScheme = scheme == "brightglow" && host == "chat"
        let isUniversalLink = scheme == "https"
            && (host == "brightglow.co" || host == "www.brightglow.co")
            && url.path.lowercased().hasPrefix("/chat")

        guard isCustomScheme || isUniversalLink else { return false }
        openInboxRequested = true
        return true
    }
}
