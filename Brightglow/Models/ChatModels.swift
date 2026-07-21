import Foundation

/// One request's conversation. Backed by a `leads` row plus its `messages` and
/// the original photo (`attachments`). The two parties are the customer
/// (leads.user_id) and the business (leads.contractor_email); `viewerIsCustomer`
/// records which side the signed-in user is on so bubbles align correctly.
struct Conversation: Identifiable, Equatable {
    let id: UUID            // lead id
    let publicId: String
    let businessName: String?
    let city: String?
    let status: String
    let createdAt: Date
    /// True when the signed-in user is the customer who sent the request; false
    /// when they're the business who received it. Drives titles and bubble sides.
    let viewerIsCustomer: Bool
    /// Attachment id of the first photo, if any — the request photo. The image
    /// itself is streamed on demand from the backend (participant-authed).
    let photoAttachmentId: UUID?
    /// The lead's Google Places id — the join key to `business_profiles`. Present
    /// on business-side threads so the dashboard can resolve and edit the page the
    /// request is addressed to; may be nil on older leads.
    let placeId: String?
    let lastMessage: String?
    let lastMessageAt: Date?
    /// True when the most recent message was authored by the counterparty (i.e.
    /// something the viewer may not have read yet). Drives the header unread dot.
    let lastMessageIncoming: Bool
    /// First letter of the customer's email — set only on business-viewed threads,
    /// where it's the letter on the initial-tile avatar. The full email is never
    /// exposed to the business (see the leads column grant). nil customer-side.
    let customerInitial: String?
    /// Stable per-customer seed for the avatar tile color (the customer's user id,
    /// already visible to the business). nil customer-side.
    let customerColorSeed: String?

    /// What to show as the conversation title. The customer sees the business;
    /// the business sees a generic customer label (their email is never exposed
    /// in text — only a single-letter avatar tile distinguishes requests).
    var title: String {
        if viewerIsCustomer { return businessName ?? "Business" }
        return "New request"
    }

    /// The letter on the business-side avatar tile — the customer's email initial,
    /// or "?" when unavailable (older lead with no generated initial).
    var avatarInitial: String {
        let i = customerInitial?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return i.isEmpty ? "?" : String(i.prefix(1)).uppercased()
    }
}

/// A single chat message. `direction` is stored relative to the customer:
/// outbound = customer→business, inbound = business→customer.
struct ConversationMessage: Identifiable, Equatable {
    let id: UUID
    let leadId: UUID
    let direction: String   // "outbound" | "inbound"
    let body: String
    let createdAt: Date

    /// True when this message was authored by the viewer (right-aligned bubble).
    func isFromViewer(customer: Bool) -> Bool {
        customer ? direction == "outbound" : direction == "inbound"
    }
}
