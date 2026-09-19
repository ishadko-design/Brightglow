import AdServices
import Foundation

/// Apple Ads install attribution — Workstream 1B.
///
/// On first launch, fetches the AdServices attribution token and POSTs it to
/// the `attribution` Edge Function alongside the stable Keychain-backed
/// device_id. The server resolves the token to campaign / ad group / keyword
/// via Apple's attribution API (token is the only credential; no Apple Ads API
/// keys needed for this step), which gives cost-per-sender per keyword for the
/// future paid test.
///
/// Best-effort like [[AnalyticsService]]: failures never affect the user's flow.
///
/// Persisted-state lifecycle (Igor's rule — read before touching):
///   (a) WRITTEN: UserDefaults key `bg_ad_attribution_reported` is set to true
///       only after the backend returns HTTP 200 for the token POST (or when
///       we learn no token can ever exist on this device — see (d)).
///   (b) READ: every launch, at the top of `reportIfNeeded()` — a set flag
///       skips all work.
///   (c) INVALIDATED: a delete+reinstall wipes UserDefaults, so the flag
///       resets and the token is re-fetched and re-POSTed. This is safe
///       because `AnalyticsService.deviceID` is Keychain-backed and SURVIVES
///       reinstall — the server dedupes first-write-wins on device_id, so a
///       reinstall can never create a second attribution row for one device.
///   (d) EDGE CASES:
///       - Simulator / restricted device: `attributionToken()` throws; the
///         framework exposes no typed error (`AAAttribution` has no
///         `AttributionError` member — verified by the compiler), so a flake
///         is indistinguishable from a device that will never yield a token.
///         Attempts are therefore capped (`bg_ad_attribution_attempts`, 3):
///         after that we mark reported and stop trying.
///       - Network flake at POST (incl. HTTP 5xx): we do NOT mark reported,
///         so the next launch retries with a FRESH token (tokens are
///         single-use and expire after ~24h — never reuse one).
///       - HTTP 4xx: the request was rejected; retrying won't help, so we
///         mark reported.
///       - Apple-side "not ready yet" (their API can 404 for up to ~24h after
///         install) is handled SERVER-side with backoff — the client doesn't
///         care and marks reported on HTTP 200 as usual.
///       - Organic install: the server exchange returns attribution:false;
///         still HTTP 200, still marked reported. "Organic" stays
///         distinguishable from "never attempted" because the server records
///         the resolution outcome per device_id.
enum AttributionReporter {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    private static let reportedKey = "bg_ad_attribution_reported"
    private static let attemptsKey = "bg_ad_attribution_attempts"
    private static let maxAttempts = 3

    /// Records a failed token-fetch attempt. Returns true once we've tried
    /// enough times that further attempts are pointless (e.g. the simulator,
    /// which throws on every launch).
    private static func noteAttempt() -> Bool {
        let n = UserDefaults.standard.integer(forKey: attemptsKey) + 1
        UserDefaults.standard.set(n, forKey: attemptsKey)
        return n >= maxAttempts
    }

    /// Call once at launch (see BrightglowApp). Reports at most once per
    /// install; every failure mode either retries next launch or marks
    /// reported per the lifecycle above.
    static func reportIfNeeded() async {
        guard AnalyticsService.isConfigured,
              !UserDefaults.standard.bool(forKey: reportedKey) else { return }

        // AdServices is iOS 14.3+; the app floor is iOS 18. Throws on
        // simulator and when no token can be issued for this install.
        // The framework exposes no typed error, so a transient flake and a
        // device that will never yield a token look identical. Retry the next
        // few launches, then give up — a simulator throws on every launch and
        // must not spin forever.
        let token: String
        do {
            token = try AAAttribution.attributionToken()
        } catch {
            if noteAttempt() { markReported() }
            return
        }
        guard !token.isEmpty else {
            if noteAttempt() { markReported() } // useless to the server
            return
        }

        guard let url = URL(string: "https://\(ref).supabase.co/functions/v1/attribution") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": AnalyticsService.deviceID,
            "attribution_token": token,
        ])

        // Any transport throw = network failure → retry next launch.
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return }
        switch status {
        case 200:
            markReported()
        case 400..<500:
            markReported() // rejected — retrying the same request won't help
        default:
            break // 5xx — server trouble, retry next launch with a fresh token
        }
    }

    private static func markReported() {
        UserDefaults.standard.set(true, forKey: reportedKey)
    }
}
