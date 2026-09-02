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
}
