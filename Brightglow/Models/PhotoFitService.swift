import Foundation

/// The LLM's final check on a results list (`photofit` Edge Function): for the
/// job the user described, which of each business's screened photos actually
/// show that job, and how well each business fits it.
///
/// Keyword overlap can't make this call — for "connect sauna electrical" every
/// electrician's breaker-panel shot shares "electrical"/"panel" with the query,
/// so the list led with panels (reported 2026-09-30). The server judges the
/// clarify chat's job spec against each photo's tags and the business's reviews.
/// Text-only (tags, not images), one call per list.
///
/// Fails open: nil on any error/timeout, and the list keeps its keyword order.
enum PhotoFitService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""

    struct Verdict: Equatable {
        /// 0 wrong business · 1 right trade, no evidence · 2 related evidence · 3 does this job.
        let fit: Int
        /// The photos that show this job (or a genuinely similar one). Empty =
        /// show this business WITHOUT photos — a wrong photo is worse than none.
        let relevant: Set<String>
        let reason: String
    }

    struct Business {
        let id: String
        let name: String
        let photos: [ScreenedPhoto]
        let reviews: [String]
    }

    static func judge(job: ClarifyTranscript, businesses: [Business]) async -> [String: Verdict]? {
        guard !ref.isEmpty, !anonKey.isEmpty, !businesses.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/photofit")
        else { return nil }

        var jobBody: [String: Any] = ["title": job.jobTitle, "summary": job.summary]
        if let spec = job.jobSpec {
            jobBody["spec"] = [
                "complexity": spec.complexity,
                "components": spec.components,
                "trades": spec.trades,
                "specialties": spec.specialties,
                "photo_match": spec.photoMatch,
                "photo_reject": spec.photoReject,
            ]
        }
        let body: [String: Any] = [
            "job": jobBody,
            "businesses": businesses.map { b in
                [
                    "id": b.id,
                    "name": b.name,
                    "photos": b.photos.map { ["url": $0.url, "tags": $0.labels] },
                    "reviews": Array(b.reviews.prefix(5)),
                ] as [String: Any]
            },
        ]

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }

        var out: [String: Verdict] = [:]
        for b in decoded.businesses {
            out[b.id] = Verdict(fit: b.fit, relevant: Set(b.relevant), reason: b.reason)
        }
        return out
    }

    private struct Response: Decodable {
        struct Row: Decodable {
            let id: String
            let fit: Int
            let relevant: [String]
            let reason: String
        }
        let businesses: [Row]
    }
}
