import Foundation

/// First-party funnel analytics for the quote-request flow. Fire-and-forget:
/// every call is best-effort and returns immediately; any failure is swallowed
/// so instrumentation never affects the user's flow.
///
/// Writes through the `record_event` SECURITY DEFINER function (see the
/// analytics_events migration) via PostgREST RPC, so no rows are ever readable
/// by the client — you read the funnel from the Supabase SQL editor.
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

    /// Record one event with free-form metadata. Non-blocking.
    static func track(_ event: String, _ props: [String: Any] = [:]) {
        guard isConfigured,
              let url = URL(string: "https://\(ref).supabase.co/rest/v1/rpc/record_event")
        else { return }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "p_event": event,
            "p_props": props,
        ])

        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}
