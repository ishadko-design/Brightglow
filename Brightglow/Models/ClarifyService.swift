import Foundation

/// One turn of the clarifying chat via the Supabase `clarify` Edge Function —
/// the AI asks up to 3 price-relevant questions (quantity, size, item type)
/// about the user's typed request, then hands back a canonical details string
/// plus category that the existing pricing flow consumes. The chat never
/// produces a price; every displayed number still comes from the pricing
/// engine's data.
///
/// Best-effort like PricingService: any failure returns nil and the caller
/// proceeds to the estimate exactly as if the chat didn't exist.
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
        case done(category: String, details: String)
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
            return .done(category: decoded.category ?? "", details: decoded.details ?? "")
        }
        return nil
    }

    private struct Response: Decodable {
        let action: String
        let question: String?
        let quick_replies: [String]?
        let category: String?
        let details: String?
    }
}
