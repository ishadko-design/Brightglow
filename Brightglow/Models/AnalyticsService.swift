import Foundation
import UIKit

/// First-party funnel analytics for the quote-request flow. Fire-and-forget:
/// every call is best-effort and returns immediately; any failure is swallowed
/// so instrumentation never affects the user's flow.
///
/// Writes through the `record_event` SECURITY DEFINER function (see the
/// analytics_events migration) via PostgREST RPC, so no rows are ever readable
/// by the client — you read the funnel from the Supabase SQL editor.
///
/// Every event carries a stable `device_id` (the vendor id) in its props. That
/// is the exclusion key: a test device is dropped from the dashboard entirely by
/// adding its id to the excluded-devices list server-side (see the analytics
/// Edge Function) — no per-device flag, and the exclusion is retroactive, so it
/// also removes that device's PAST events from every number.
///
/// The two events that matter (both fired from [[QuoteRequestScreen]]):
///   send_tapped  — the in-app "Send" CTA was tapped (the composer opens)
///   send_result  — the composer closed; props["outcome"] = sent|cancelled|failed
enum AnalyticsService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// Stable per-device identifier stamped on every event — the exclusion key
    /// the dashboard's Devices card acts on.
    ///
    /// Backed by the Keychain (generated once, on first launch) so it SURVIVES
    /// delete+reinstall and distribution-channel switches (Xcode → TestFlight →
    /// App Store all keep the same id). That means a device excluded once stays
    /// excluded for good, unlike raw `identifierForVendor`, which regenerates on
    /// reinstall. Seeded from the vendor id (falling back to a random uuid) the
    /// first time only; thereafter the stored value is authoritative.
    static var deviceID: String {
        if let existing = KeychainStore.get("bg_device_id") { return existing }
        let fresh = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        KeychainStore.set("bg_device_id", fresh)
        return fresh
    }

    /// Record one event with free-form metadata. Non-blocking.
    static func track(_ event: String, _ props: [String: Any] = [:]) {
        guard isConfigured,
              let url = URL(string: "https://\(ref).supabase.co/rest/v1/rpc/record_event")
        else { return }

        var merged = props
        merged["device_id"] = deviceID   // exclusion key; never overwritten by callers below

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "p_event": event,
            "p_props": merged,
        ])

        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}

/// Minimal Keychain-backed string store. Used to persist the analytics device id
/// across app reinstalls (UserDefaults does not survive a delete+reinstall;
/// Keychain does). One generic-password item per key.
enum KeychainStore {
    private static let service = "co.brightglow.analytics"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func get(_ account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var q = baseQuery(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
