import UIKit

/// Client for the LeadBridge relay API (leadbridge/ — separate Node/Express
/// service, not the Supabase Edge Functions the rest of the app talks to).
/// Not a secret: this is just the service's public base URL, same nature as
/// its RELAY_DOMAIN.
enum LeadBridgeService {
    private static let baseURL = "https://leadbridge-production-4065.up.railway.app"

    enum SubmitError: Error {
        case encodingFailed
        case requestFailed(status: Int, body: String)
        case transport(Error)
    }

    /// POSTs a lead (photo + description) to LeadBridge. Returns the
    /// lead's public_id on success. businessName personalizes the email
    /// greeting when known (e.g. from Places via the browsed Contractor) —
    /// LeadBridge has no other source for a contractor's name.
    static func submitLead(
        userEmail: String,
        userId: UUID? = nil,
        contractorEmail: String,
        businessName: String? = nil,
        description: String,
        city: String,
        photo: UIImage
    ) async throws -> String {
        guard let jpegData = photo.jpegData(compressionQuality: 0.85) else {
            throw SubmitError.encodingFailed
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
        appendField("description", description)
        appendField("city", city)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n".data(using: .utf8)!)
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
}
