import UIKit
import Supabase

/// Client for the LeadBridge relay API (leadbridge/ — separate Node/Express
/// service, not the Supabase Edge Functions the rest of the app talks to).
/// Not a secret: this is just the service's public base URL, same nature as
/// its RELAY_DOMAIN.
enum LeadBridgeService {
    static let baseURL = "https://leadbridge-production-4065.up.railway.app"

    enum SubmitError: Error {
        case encodingFailed
        case requestFailed(status: Int, body: String)
        case transport(Error)
    }

    /// POSTs a lead (description, optionally a photo) to LeadBridge. Returns
    /// the lead's public_id on success. businessName personalizes the email
    /// greeting when known (e.g. from Places via the browsed Contractor) —
    /// LeadBridge has no other source for a contractor's name.
    /// An unguessable lead id matching the server's `lead_<base36>` shape. The
    /// P2P text path mints this BEFORE opening the SMS composer so the `/l/<id>`
    /// reply link can go in the message body; the lead is only created (with this
    /// id) if the user actually sends. 16 chars of base36 ≈ 82 bits of entropy.
    static func newPublicID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = (0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return "lead_" + String(suffix)
    }

    /// Public web page (no login) where the business sees this request + photo
    /// and replies into the customer's chat. Built from `publicId`.
    static func replyURL(publicId: String) -> String { "\(baseURL)/l/\(publicId)" }

    static func submitLead(
        userEmail: String,
        userId: UUID? = nil,
        contractorEmail: String,
        businessName: String? = nil,
        placeId: String? = nil,
        website: String? = nil,
        description: String,
        city: String,
        photo: UIImage? = nil,
        publicId: String? = nil,
        notify: Bool = true
    ) async throws -> String {
        // Photo is optional; when there is one, failing to encode it is still
        // an error rather than a silent text-only send.
        var jpegData: Data? = nil
        if let photo {
            guard let encoded = photo.jpegData(compressionQuality: 0.85) else {
                throw SubmitError.encodingFailed
            }
            jpegData = encoded
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "\(baseURL)/api/leads")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("user_email", userEmail)
        if let userId { appendField("user_id", userId.uuidString) }
        appendField("contractor_email", contractorEmail)
        if let businessName, !businessName.isEmpty { appendField("business_name", businessName) }
        // Business identity for the chat logo avatar — best-effort, safe to omit.
        if let placeId, !placeId.isEmpty { appendField("place_id", placeId) }
        if let website, !website.isEmpty { appendField("website", website) }
        appendField("description", description)
        appendField("city", city)
        // P2P text path: the app-minted id (so the SMS link is known up front) and
        // `notify=false` so LeadBridge records the lead for the /l/<id> reply page
        // but sends no email — the customer's own text is the delivery.
        if let publicId, !publicId.isEmpty { appendField("public_id", publicId) }
        if !notify { appendField("notify", "false") }

        if let jpegData {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(jpegData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SubmitError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SubmitError.requestFailed(status: -1, body: "no response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SubmitError.requestFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct LeadResponse: Decodable { let public_id: String }
        let decoded = try JSONDecoder().decode(LeadResponse.self, from: data)
        return decoded.public_id
    }

    // MARK: - Chat

    /// Posts a chat message to a lead's thread. The backend verifies the
    /// caller's Supabase JWT, derives the message direction from which party
    /// they are, stores it, and relays an email to the counterparty. Returns
    /// the created message so the sender can render it immediately.
    /// `fromCustomer` is advisory only — the server is the source of truth for
    /// direction — but is kept so the caller's intent is explicit at the call site.
    static func sendMessage(publicId: String, body: String, fromCustomer: Bool) async throws -> ConversationMessage {
        let token = try await supabase.auth.session.accessToken

        var req = URLRequest(url: URL(string: "\(baseURL)/api/threads/\(publicId)/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SubmitError.requestFailed(status: -1, body: "no response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SubmitError.requestFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct Envelope: Decodable { let message: Row }
        struct Row: Decodable {
            let id: UUID
            let lead_id: UUID
            let direction: String
            let body_text: String?
            let created_at: Date
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(Envelope.self, from: data).message
        return ConversationMessage(
            id: row.id, leadId: row.lead_id, direction: row.direction,
            body: row.body_text ?? body, createdAt: row.created_at
        )
    }

    /// Streams a lead's photo (a private Storage object) through the backend,
    /// which checks the caller is a participant on the lead before serving it.
    static func fetchAttachment(id: UUID) async throws -> Data {
        let token = try await supabase.auth.session.accessToken
        var req = URLRequest(url: URL(string: "\(baseURL)/api/attachments/\(id.uuidString)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Always hit the server — never read a cached response. iOS caches a
        // `410 Gone` (a heuristically-cacheable status) on disk, so a transient
        // server-side failure would otherwise stick permanently, returning the
        // stale 410 forever without ever re-contacting the (now-healthy) backend.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SubmitError.requestFailed(status: status, body: "")
        }
        return data
    }
}
