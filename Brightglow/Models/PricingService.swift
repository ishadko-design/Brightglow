import Foundation

/// Calls the Supabase `pricing` Edge Function for a data-backed cost range:
/// SF DBI building permits, blended with retail material pricing when
/// available (SerpApi's Home Depot engine), or shown as a permit-only range
/// when it isn't (no `SERPAPI_KEY` configured, or a category with no
/// material lookup) — real permit data beats no number at all.
/// `EstimateService.estimate` tries this first; if it returns nil (job/
/// locality not covered, or the call fails), callers show "Coming soon".
///
/// Coverage is intentionally narrow: only jobs recognized as
/// `bathroom.vanity` or `bathroom.full` (keyword match, mirrors
/// `NORMALIZE_RULES` in the pricing engine), and only when the locality is
/// San Francisco. The client sends only the job — material pricing is
/// sourced server-side, so there's nothing else to wire up here.
enum PricingService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// job_type -> keywords, mirrors `NORMALIZE_RULES` in the pricing engine.
    /// Order matters: more specific matches (vanity) must be checked before
    /// broader ones (full bath) since `detectJobType` takes the first hit.
    private static let jobTypeKeywords: [(jobType: String, keywords: [String])] = [
        ("bathroom.vanity", ["vanity"]),
        ("bathroom.full", ["full bath", "bathroom remodel", "bathroom renovation"]),
        ("plumbing.water_heater", ["water heater"]),
        ("electrical.panel", ["panel upgrade", "electrical panel", "breaker panel"]),
        ("hvac.furnace", ["furnace"]),
        ("windows_doors.window", ["window replacement", "replace window", "new window"]),
        ("carpentry.deck", ["deck"]),
    ]

    /// Best-effort local range for a job. Returns nil (never throws) if the
    /// job/locality isn't covered or the call fails — callers should fall
    /// back to the LLM estimate.
    static func estimate(job: String, locality: String) async -> PriceTier? {
        guard isConfigured,
              locality.localizedCaseInsensitiveContains("San Francisco"),
              let jobType = detectJobType(in: job),
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/pricing")
        else { return nil }

        let widthIn = detectWidthIn(in: job) ?? 36
        let body: [String: Any] = [
            "job_type": jobType,
            "scope": ["job_type": jobType, "width_in": widthIn, "features": [String]()],
        ]

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

        // Surfaces the evidence behind the number rather than a bare range —
        // the label is what makes this more credible than a generic
        // estimate, so callers render it directly instead of "Est prices:".
        // `materials_included` distinguishes the full permits+materials
        // range from the permit-only fallback (no SERPAPI_KEY, or a
        // category with no material lookup) — explicitly labeled as permit
        // data so it's never confused with the fuller breakdown.
        let permitWord = "SF permit\(range.data_points == 1 ? "" : "s")"
        let label = range.materials_included
            ? "Local avg (\(range.data_points) \(permitWord))"
            : "\(range.data_points) \(permitWord) — permit data only"
        return PriceTier(label: label, min: Int(range.all_in_low.rounded()), max: Int(range.all_in_high.rounded()))
    }

    private static func detectJobType(in job: String) -> String? {
        let text = job.lowercased()
        return jobTypeKeywords.first { pair in pair.keywords.contains { text.contains($0) } }?.jobType
    }

    private static func detectWidthIn(in job: String) -> Int? {
        guard let rx = try? NSRegularExpression(pattern: #"(\d+)\s*(?:in\b|inch|")"#) else { return nil }
        let ns = job as NSString
        guard let m = rx.firstMatch(in: job, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    /// Only decodes the success shape; the {error, fallback} shape decodes
    /// `range` to nil, which the caller treats as "fall back to the LLM".
    private struct Response: Decodable {
        let range: Range?

        struct Range: Decodable {
            let all_in_low: Double
            let all_in_high: Double
            let data_points: Int
            let materials_included: Bool
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.range = try? c.decode(Range.self, forKey: .range)
        }

        enum CodingKeys: String, CodingKey { case range }
    }
}
