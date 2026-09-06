import Foundation

/// Build-time feature switches.
enum FeatureFlags {
    /// Account-based features: in-app chat conversations, the business dashboard,
    /// and the consumer profile / sign-in wall.
    ///
    /// Held OFF for the consumer-only App Store build. App Review Guideline
    /// 5.1.1(v) forbids requiring login to reach features that aren't
    /// account-based, and with in-app chat currently retired there is nothing
    /// account-based left on the consumer side — browsing, estimates, calling and
    /// texting a pro all work anonymously. Business owners manage their listing on
    /// the web portal (brightglow.co/biz).
    ///
    /// Flip this back to `true` to restore the in-app chat / business / profile
    /// surfaces (the code is intact) — e.g. when in-app conversations return, at
    /// which point login is legitimately required *for that feature* and passes
    /// review.
    static let accountFeaturesEnabled = false

    /// Speculatively pre-warm the grounded (web-searched) estimate for a handful of
    /// common jobs in the user's metro, the moment a location resolves — so those
    /// specific searches show a price instantly.
    ///
    /// OFF by default because it costs paid web searches up front, before the user
    /// searches anything: cached server-side per job+metro for 14 days (so it's
    /// amortized across a metro's users), but the first user in a new metro pays for
    /// the whole list whether or not they want those jobs, and the hit rate is
    /// limited (the cache is keyed on the exact job phrasing). The capture-time
    /// prefetch already warms the user's ACTUAL job, which is the higher-value path.
    /// Flip to `true` to accept that trade for instant common-job estimates.
    static let prewarmPopularEstimates = false
}
