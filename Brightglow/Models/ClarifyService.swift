import Foundation

/// One turn of the clarifying chat via the Supabase `clarify` Edge Function.
/// Its primary job is to disambiguate toward the right LOCAL BUSINESS: it asks
/// a scalable number of questions (1 for a clear job, up to ~7 for an ambiguous
/// one) and hands back a `ClarifyOutcome` — a business-search phrase and
/// photo-match terms that drive the results ranking, plus (for covered home
/// trades only) canonical pricing `details`. The chat never produces a price;
/// every displayed number still comes from the pricing engine's data.
///
/// Best-effort like PricingService: any failure returns nil and the caller
/// proceeds to results exactly as if the chat didn't exist.
enum ClarifyService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    struct Turn: Codable, Equatable {
        let role: String   // "user" | "assistant"
        let content: String
    }

    enum Reply {
        case ask(question: String, quickReplies: [String])
        case done(ClarifyOutcome)
    }

    /// The chat's final match result. `searchTerms` refines the business search
    /// and `photoTerms` ranks each business's work photos ("did a similar job");
    /// `details`/`priceable` are the secondary pricing layer — `priceable` is
    /// false for auto/moto and any category the pricing engine doesn't cover.
    struct ClarifyOutcome: Equatable {
        let vertical: String        // "home" | "auto_moto"
        let category: String
        let searchTerms: String
        let photoTerms: String
        let details: String
        let priceable: Bool
    }

    /// Next chat turn. `messages` is the full history (first entry = the
    /// user's original request); `photoDetails` is the vision model's
    /// extracted attributes, giving the AI the photo context.
    static func next(messages: [Turn], photoDetails: String?) async -> Reply? {
        guard isConfigured, !messages.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/clarify")
        else { return nil }

        var body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if let photoDetails, !photoDetails.isEmpty { body["photo_details"] = photoDetails }

        var req = URLRequest(url: url, timeoutInterval: 25)
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

        if decoded.action == "ask", let question = decoded.question, !question.isEmpty {
            return .ask(question: question, quickReplies: decoded.quick_replies ?? [])
        }
        if decoded.action == "done" {
            let vertical = decoded.vertical ?? "home"
            return .done(ClarifyOutcome(
                vertical: vertical,
                category: decoded.category ?? "",
                searchTerms: decoded.search_terms ?? "",
                photoTerms: decoded.photo_terms ?? "",
                details: decoded.details ?? "",
                priceable: decoded.priceable ?? (vertical == "home")
            ))
        }
        return nil
    }

    private struct Response: Decodable {
        let action: String
        let question: String?
        let quick_replies: [String]?
        let vertical: String?
        let category: String?
        let search_terms: String?
        let photo_terms: String?
        let details: String?
        let priceable: Bool?
    }
}
