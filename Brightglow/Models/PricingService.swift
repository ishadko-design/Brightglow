import Foundation

/// Calls the Supabase `pricing` Edge Function for a data-backed cost range,
/// nationwide, across all of the app's home categories: EstimationPro's
/// regional construction-cost data (BLS-backed) is the primary source,
/// cross-checked against SF DBI permits for the few job types that overlap.
/// `EstimateService.estimate` tries this first; if it returns nil (category
/// not covered — currently only Mold & Pest Control — or the call fails),
/// callers show "Coming soon".
///
/// Classification (which specific job within a category this is) now
/// happens server-side against a shared taxonomy, so it can evolve without
/// an app release and isn't duplicated between client and server. The
/// client's job here is just to always send what it knows: the selected
/// category (required), and the free-text job description (typed search
/// text plus any photo-derived detail text the caller appends) — the
/// backend classifies from there.
enum PricingService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// Best-effort local range for a job. Returns nil (never throws) if the
    /// category isn't covered or the call fails — callers fall back to the
    /// "coming soon" placeholder.
    ///
    /// Either field alone is enough: a category chip with no typed text
    /// prices via the server's category-general entry, and a bare typed
    /// description (the common search path — no chip, and no category is
    /// recoverable from a multi-word phrase) is classified server-side from
    /// job keywords. Requiring a category here silently unpriced every
    /// typed search.
    /// - Parameter vehicle: the Auto/Moto filter, for the Auto & moto vertical.
    ///   The server cannot recover this from the words alone — "replace tires"
    ///   is the same phrase for both — and without it a motorcycle request was
    ///   priced as four car tires (~$890) instead of two moto tires (~$440).
    ///   Nil for home categories.
    static func estimate(category: String, description: String, zip: String?,
                         vehicle: VehicleFilter? = nil) async -> PriceTier? {
        guard isConfigured, !category.isEmpty || !description.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/pricing")
        else { return nil }

        var body: [String: Any] = ["category": category, "description": description]
        if let zip { body["zip"] = zip }
        if let vehicle { body["vehicle"] = vehicle == .moto ? "moto" : "auto" }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let range = decoded.range
        else { return nil }

        // The server already composes a label reflecting its own provenance
        // (plain regional average, vs. cross-checked against N SF permits,
        // vs. legacy permit-only) — the client just displays it rather than
        // reconstructing it from raw fields.
        return PriceTier(label: range.label,
                         min: Int(range.all_in_low.rounded()),
                         max: Int(range.all_in_high.rounded()),
                         typical: range.all_in_typical.map { Int($0.rounded()) },
                         laborOnly: range.labor_only ?? false)
    }

    /// Only decodes the success shape; the {error, fallback} shape decodes
    /// `range` to nil, which the caller treats as "fall back to coming soon".
    private struct Response: Decodable {
        let range: Range?

        struct Range: Decodable {
            let all_in_low: Double
            let all_in_high: Double
            let all_in_typical: Double?
            let confidence: String
            let label: String
            /// True when the figure covers LABOR ONLY (a job outside the
            /// catalog, where parts are excluded rather than guessed) — the
            /// header must say so, or the number reads as an all-in price.
            let labor_only: Bool?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.range = try? c.decode(Range.self, forKey: .range)
        }

        enum CodingKeys: String, CodingKey { case range }
    }
}
