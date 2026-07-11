import Foundation
import Supabase

/// Reads chat data straight from Supabase (RLS gates each row to a participant)
/// and streams live replies over Realtime. Writes go through LeadBridge instead
/// — see `LeadBridgeService.sendMessage` — so the same insert also fires the
/// email relay to a counterparty who isn't currently in the app.
enum ChatService {

    // MARK: - Decoding rows (PostgREST resource embedding)

    private struct LeadRow: Decodable {
        let id: UUID
        let public_id: String
        let business_name: String?
        let city: String?
        let status: String
        let created_at: Date
        let user_id: UUID?
        let messages: [MessageRow]
        let attachments: [AttachmentRow]
    }

    private struct MessageRow: Decodable {
        let id: UUID
        let lead_id: UUID
        let direction: String
        let body_text: String?
        let created_at: Date
    }

    private struct AttachmentRow: Decodable {
        let id: UUID
    }

    // MARK: - Unread / read tracking

    /// Per-thread "last opened" timestamps, keyed by lead id. A conversation is
    /// unread when its newest message is incoming and arrived after the viewer
    /// last opened *that thread* — so reviewing one thread clears only its own
    /// indicator, not the whole inbox. Read state is per-device (local only).
    private static let threadReadKey = "chatThreadReadAt"

    private static func threadReads() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: threadReadKey) as? [String: Double] ?? [:]
    }

    /// Mark a thread read up to now — call when the user opens/leaves it.
    static func markThreadRead(_ leadId: UUID) {
        var map = threadReads()
        map[leadId.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(map, forKey: threadReadKey)
    }

    private static func lastRead(_ leadId: UUID) -> Date {
        Date(timeIntervalSince1970: threadReads()[leadId.uuidString] ?? 0)
    }

    /// True when a conversation has an incoming message newer than the last time
    /// the viewer opened it — drives the row dot and the main-screen header dot.
    static func isUnread(_ c: Conversation) -> Bool {
        c.lastMessageIncoming && (c.lastMessageAt ?? .distantPast) > lastRead(c.id)
    }

    /// True when any conversation is unread. Best-effort: a failure reports none.
    static func hasUnread() async -> Bool {
        guard let convos = try? await conversations() else { return false }
        return convos.contains(where: isUnread)
    }

    // MARK: - Conversations list

    /// Every conversation the signed-in user is a party to, newest activity
    /// first. One round trip: leads with their messages + attachments embedded.
    static func conversations() async throws -> [Conversation] {
        let myId = try? await supabase.auth.session.user.id

        let rows: [LeadRow] = try await supabase
            .from("leads")
            .select("id, public_id, business_name, city, status, created_at, user_id, messages(id, lead_id, direction, body_text, created_at), attachments(id)")
            .order("created_at", ascending: false)
            .execute()
            .value

        return rows.map { row in
            let sorted = row.messages.sorted { $0.created_at < $1.created_at }
            let last = sorted.last
            let viewerIsCustomer = row.user_id != nil && row.user_id == myId
            // Incoming = the last message came from the other party. Direction is
            // stored relative to the customer (outbound = customer→business).
            let incoming = last.map { msg in
                viewerIsCustomer ? msg.direction == "inbound" : msg.direction == "outbound"
            } ?? false
            return Conversation(
                id: row.id,
                publicId: row.public_id,
                businessName: row.business_name,
                city: row.city,
                status: row.status,
                createdAt: row.created_at,
                viewerIsCustomer: viewerIsCustomer,
                photoAttachmentId: row.attachments.first?.id,
                lastMessage: last?.body_text,
                lastMessageAt: last?.created_at,
                lastMessageIncoming: incoming
            )
        }
        // Order by most recent message, falling back to the lead's own time.
        .sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }
    }

    // MARK: - One thread

    static func messages(leadId: UUID) async throws -> [ConversationMessage] {
        let rows: [MessageRow] = try await supabase
            .from("messages")
            .select("id, lead_id, direction, body_text, created_at")
            .eq("lead_id", value: leadId.uuidString)
            .order("created_at", ascending: true)
            .execute()
            .value

        return rows.map {
            ConversationMessage(
                id: $0.id,
                leadId: $0.lead_id,
                direction: $0.direction,
                body: $0.body_text ?? "",
                createdAt: $0.created_at
            )
        }
    }

    // MARK: - Realtime

    /// Streams messages inserted into this lead after subscription. The caller
    /// awaits the returned stream on a Task and cancels it (which unsubscribes)
    /// when the thread closes. Realtime re-applies the SELECT policy per
    /// subscriber, so only a participant ever receives these rows.
    static func liveMessages(leadId: UUID) -> AsyncStream<ConversationMessage> {
        AsyncStream { continuation in
            let channel = supabase.channel("chat:\(leadId.uuidString)")
            let inserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "messages",
                filter: "lead_id=eq.\(leadId.uuidString)"
            )

            let task = Task {
                await channel.subscribe()
                for await insert in inserts {
                    if let msg = decode(insert.record) {
                        continuation.yield(msg)
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task { await supabase.removeChannel(channel) }
            }
        }
    }

    /// Realtime payloads arrive as a JSON object keyed by column. Decode the
    /// fields we need; drop the row on any shape mismatch rather than crash.
    private static func decode(_ record: [String: AnyJSON]) -> ConversationMessage? {
        guard
            let idStr = record["id"]?.stringValue, let id = UUID(uuidString: idStr),
            let leadStr = record["lead_id"]?.stringValue, let leadId = UUID(uuidString: leadStr),
            let direction = record["direction"]?.stringValue
        else { return nil }
        let body = record["body_text"]?.stringValue ?? ""
        let createdAt = record["created_at"]?.stringValue
            .flatMap { ISO8601DateFormatter.chat.date(from: $0) } ?? Date()
        return ConversationMessage(id: id, leadId: leadId, direction: direction, body: body, createdAt: createdAt)
    }
}

private extension ISO8601DateFormatter {
    /// Postgres timestamptz over Realtime includes fractional seconds.
    static let chat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
