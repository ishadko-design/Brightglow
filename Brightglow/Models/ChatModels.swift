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
    let lastMessage: String?
    let lastMessageAt: Date?

    /// What to show as the conversation title. The customer sees the business;
    /// the business sees a generic customer label (their email is never exposed).
    var title: String {
        if viewerIsCustomer { return businessName ?? "Business" }
        return "New request"
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
