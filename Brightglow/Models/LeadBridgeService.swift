import UIKit
import Supabase

/// Client for the LeadBridge relay API (leadbridge/ — separate Node/Express
/// service, not the Supabase Edge Functions the rest of the app talks to).
/// Not a secret: this is just the service's public base URL, same nature as
/// its RELAY_DOMAIN.
enum LeadBridgeService {
    // ⚠️ TEST OVERRIDE — point the app at your LOCAL leadbridge (billing is ON
    // there, so the paywall actually engages and you get the new /l page)
    // instead of production. Empty string = production. MUST be "" before ship.
    private static let testBaseURL = ""   // HTTPS tunnel to local; "" for prod
    static var baseURL: String {
        testBaseURL.isEmpty ? "https://leadbridge-production-4065.up.railway.app" : testBaseURL
    }

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

    /// Public web page (no login) where the business sees this request + photo.
    /// Read-only detail view — the business replies in their own text thread.
    /// Built from `publicId`. Lives on our own domain (the worker proxies /l/*
    /// to LeadBridge) so the SMS link says brightglow.co, not a Railway URL.
    static var replyBaseURL: String {
        testBaseURL.isEmpty ? "https://brightglow.co" : testBaseURL
    }
    static func replyURL(publicId: String) -> String { "\(replyBaseURL)/l/\(publicId)" }

    /// Read-only pre-send quota check: is this business already over its free-lead
    /// allowance? If so the text should be the thin "details behind the link" form
    /// (the `/l` page then shows the paywall) rather than the full-detail text.
    /// Fails OPEN — returns false on any error, timeout, or when billing is off —
    /// so a network hiccup never blocks a send or downgrades a free lead. Worst
    /// case a lead goes out full, which is the intended default.
    static func checkGate(placeId: String, contractorEmail: String) async -> Bool {
        guard !placeId.isEmpty,
              var comps = URLComponents(string: "\(baseURL)/api/leads/gate") else { return false }
        comps.queryItems = [
            URLQueryItem(name: "place_id", value: placeId),
            URLQueryItem(name: "contractor_email", value: contractorEmail),
        ]
        guard let url = comps.url else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            struct GateResponse: Decodable { let over_quota: Bool }
            return (try? JSONDecoder().decode(GateResponse.self, from: data))?.over_quota ?? false
        } catch {
            return false
        }
    }

    static func submitLead(
        userEmail: String,
        userId: UUID? = nil,
        contractorEmail: String,
        businessName: String? = nil,
        placeId: String? = nil,
        website: String? = nil,
        contractorPhone: String? = nil,
        description: String,
        city: String? = nil,
        photos: [UIImage] = [],
        publicId: String? = nil,
        notify: Bool = true,
        contactConsent: Bool = false,
        deviceId: String? = nil,
        jobTitle: String? = nil
    ) async throws -> String {
        // Photos are optional; when there are any, failing to encode one is still
        // an error rather than a silent partial send. LeadBridge accepts up to 5.
        var jpegDatas: [Data] = []
        for photo in photos.prefix(5) {
            guard let encoded = photo.jpegData(compressionQuality: 0.85) else {
                throw SubmitError.encodingFailed
            }
            jpegDatas.append(encoded)
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
        // The business phone we're texting — stored so the business can later claim
        // its leads by verifying this number via OTP (the /biz phone-first identity).
        if let contractorPhone, !contractorPhone.isEmpty { appendField("contractor_phone", contractorPhone) }
        appendField("description", description)
        if let city, !city.isEmpty { appendField("city", city) }
        // P2P text path: the app-minted id (so the SMS link is known up front) and
        // `notify=false` so LeadBridge records the lead for the /l/<id> reply page
        // but sends no email — the customer's own text is the delivery.
        if let publicId, !publicId.isEmpty { appendField("public_id", publicId) }
        if !notify { appendField("notify", "false") }
        // Consent record: the customer ticked "the business can text me back" on
        // the confirmation screen. Stored on the lead as dated proof.
        if contactConsent { appendField("contact_consent", "true") }
        // The customer's app device (AnalyticsService.deviceID). LeadBridge
        // stamps it onto the link_opened analytics event so the dashboard can
        // ratio opens per customer. Best-effort; older servers ignore it.
        if let deviceId, !deviceId.isEmpty { appendField("sender_device_id", deviceId) }
        // The clarify LLM's 3-5 word job title ("metal trim replacement").
        // LeadBridge stores it on the lead and renders it as the request
        // title on the /l page and /biz portal. Omitted when clarify was
        // skipped or failed — older servers ignore unknown fields anyway.
        if let jobTitle, !jobTitle.isEmpty { appendField("job_title", jobTitle) }

        // Every attached photo goes as its own `photo` field — multer's
        // upload.array('photo', 5) collects them into req.files in order.
        for (i, jpegData) in jpegDatas.enumerated() {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo\(i).jpg\"\r\n".data(using: .utf8)!)
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
            // 409 = a lead with this app-minted publicId already exists: the
            // earlier save landed but its response was lost. The lead is
            // there, so treat the retry as success instead of stranding it.
            if http.statusCode == 409, let publicId { return publicId }
            throw SubmitError.requestFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct LeadResponse: Decodable { let public_id: String }
        let decoded = try JSONDecoder().decode(LeadResponse.self, from: data)
        return decoded.public_id
    }

    /// Retracts a lead by its public id. Best-effort and non-throwing: used
    /// when the user cancels the SMS composer after the pre-compose save, so
    /// the business never sees a request that was never sent.
    static func deleteLead(publicId: String) async {
        guard let url = URL(string: "\(baseURL)/api/leads/\(publicId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            print("⚠️ lead retract failed: \(error)")
        }
    }

    /// Records a phone-tap engagement so a call meters toward the business's free
    /// allowance, same as a text or an email lead. Fire-and-forget — never blocks
    /// (or delays) handing off to the dialer.
    static func recordCall(placeId: String, businessName: String?, website: String?,
                           city: String?, contractorEmail: String, contractorPhone: String? = nil) {
        guard !placeId.isEmpty, let url = URL(string: "\(baseURL)/api/leads/engagement") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = ["place_id": placeId, "contractor_email": contractorEmail]
        if let businessName, !businessName.isEmpty { payload["business_name"] = businessName }
        if let website, !website.isEmpty { payload["website"] = website }
        if let city, !city.isEmpty { payload["city"] = city }
        // Same claim anchor as the lead path: a call is often the only touch, so
        // record the number here too or an email-less business could never be claimed.
        if let contractorPhone, !contractorPhone.isEmpty { payload["contractor_phone"] = contractorPhone }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
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
