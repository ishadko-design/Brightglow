import Foundation

/// Decides when to ask for an App Store rating. Ratings are the biggest ASO
/// lever we lack, so we ask at the happiest moment — right after a request
/// actually reached a business — and nowhere else.
///
/// Apple already caps the system prompt at 3 showings per 365 days (and may
/// show nothing at all), so this only adds our own restraint on top: at most
/// once per app version, right after the user's first successful send — most
/// people only ever send once, so waiting for a second would never ask.
enum ReviewPrompter {
    private static let sendCountKey = "review.successfulSends"
    private static let lastPromptedVersionKey = "review.lastPromptedVersion"
    private static let minSends = 1

    /// Records a successful send and returns true if now is the moment to ask.
    static func recordSuccessfulSend() -> Bool {
        #if DEBUG
        return true // dev builds: always ask so the flow is testable
        #else
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: sendCountKey) + 1
        defaults.set(count, forKey: sendCountKey)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard count >= minSends,
              defaults.string(forKey: lastPromptedVersionKey) != version else { return false }
        defaults.set(version, forKey: lastPromptedVersionKey)
        return true
        #endif
    }
}
