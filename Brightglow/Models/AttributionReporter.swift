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
///       - Simulator / restricted device: `attributionToken()` throws; we mark
///         reported so we never spam retries for a token that can't exist.
///       - Network flake at token fetch or POST (incl. HTTP 5xx): we do NOT
///         mark reported, so the next launch retries with a FRESH token
///         (tokens are single-use and expire after ~24h — never reuse one).
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

    /// Call once at launch (see BrightglowApp). Reports at most once per
    /// install; every failure mode either retries next launch or marks
    /// reported per the lifecycle above.
    static func reportIfNeeded() async {
        guard AnalyticsService.isConfigured,
              !UserDefaults.standard.bool(forKey: reportedKey) else { return }

        // AdServices is iOS 14.3+; the app floor is iOS 18. Throws on
        // simulator and when no token can be issued for this install.
        let token: String
        do {
            token = try AAAttribution.attributionToken()
        } catch let err as AAAttribution.AttributionError {
            switch err {
            case .networkError:
                return // flaky first-launch network — retry next launch
            case .internalError:
                markReported() // no token will ever exist here — don't spam
                return
            @unknown default:
                markReported()
                return
            }
        } catch {
            markReported() // simulator / unknown throw — nothing to retry
            return
        }
        guard !token.isEmpty else { return } // useless to the server — retry next launch

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
