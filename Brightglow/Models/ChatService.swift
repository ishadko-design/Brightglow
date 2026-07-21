import Foundation
import Supabase

/// Reads chat data straight from Supabase (RLS gates each row to a participant)
/// and streams live replies over Realtime. Writes go through LeadBridge instead
/// — see `LeadBridgeService.sendMessage` — so the same insert also fires the
/// email relay to a counterparty who isn't currently in the app.
enum ChatService {

    // MARK: - Decoding rows (PostgREST resource embedding)

    /// A `leads` row with its messages + attachments embedded. Shared with
    /// `BusinessService` (which selects the same shape for the dashboard) so both
    /// map a lead to a `Conversation` through `makeConversation`. `website` is only
    /// selected by the business query; it decodes as nil elsewhere.
    struct LeadRow: Decodable {
        let id: UUID
        let public_id: String
        let business_name: String?
        let city: String?
        let status: String
        let created_at: Date
        let user_id: UUID?
        let place_id: String?
        let website: String?
        /// Just the first letter of the customer's email (a generated column —
        /// the full `user_email` is deliberately never granted to participants).
        /// Used business-side for the initial-tile avatar. Optional so a query
        /// that doesn't select it still decodes.
        let user_email_initial: String?
        /// The inbox the request was matched to — who owns it as a business. Only
        /// the business query selects it; nil elsewhere.
        let contractor_email: String?
        let messages: [MessageRow]
        let attachments: [AttachmentRow]
    }

    struct MessageRow: Decodable {
        let id: UUID
        let lead_id: UUID
        let direction: String
        let body_text: String?
        let created_at: Date
    }

    struct AttachmentRow: Decodable {
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

    // MARK: - Hidden (locally deleted) conversations

    /// Conversations the user swiped away from THEIR inbox. Local per-device,
    /// like read state — the underlying lead is left intact (the business still
    /// sees the thread), so this hides it here without destroying shared data.
    private static let hiddenKey = "chatHiddenThreads"

    static func hiddenConversationIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    /// Hide a conversation from the inbox — persists across launches.
    static func hideConversation(_ leadId: UUID) {
        var ids = hiddenConversationIDs()
        ids.insert(leadId.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: hiddenKey)
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
            .select("id, public_id, business_name, city, status, created_at, user_id, user_email_initial, place_id, messages(id, lead_id, direction, body_text, created_at), attachments(id)")
            .order("created_at", ascending: false)
            .execute()
            .value

        let hidden = hiddenConversationIDs()
        return rows.map { makeConversation(from: $0, myId: myId) }
        // Drop conversations the user swiped away on this device.
        .filter { !hidden.contains($0.id.uuidString) }
        // Order by most recent message, falling back to the lead's own time.
        .sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }
    }

    /// Map an embedded `leads` row (+ its messages/attachments) to a `Conversation`,
    /// deciding the viewer's side from the signed-in user id. Shared by the inbox
    /// and the business dashboard so both read a lead the same way.
    /// `viewerIsCustomerOverride` forces which side the viewer is on — the business
    /// dashboard passes `false` so a request always renders as the business (even a
    /// self-test lead where the same account is both customer and contractor, which
    /// would otherwise resolve to the customer side).
    static func makeConversation(from row: LeadRow, myId: UUID?,
                                 viewerIsCustomerOverride: Bool? = nil) -> Conversation {
        let sorted = row.messages.sorted { $0.created_at < $1.created_at }
        let last = sorted.last
        let viewerIsCustomer = viewerIsCustomerOverride ?? (row.user_id != nil && row.user_id == myId)
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
            placeId: row.place_id,
            lastMessage: last?.body_text,
            lastMessageAt: last?.created_at,
            lastMessageIncoming: incoming,
            // Only carried business-side, where they seed the initial avatar; the
            // customer sees the business logo, not a tile.
            customerInitial: viewerIsCustomer ? nil : row.user_email_initial,
            customerColorSeed: viewerIsCustomer ? nil : row.user_id?.uuidString
        )
    }

    private struct LeadIdentityRow: Decodable {
        let id: UUID
        let place_id: String?
        let website: String?
    }

    /// Resolve the business logo for each conversation, keyed by lead id, so the
    /// inbox and thread can draw it as the avatar. Only the customer's side has a
    /// business to show (the business sees a generic customer), so business-viewed
    /// threads are skipped. Best-effort and cross-user cached (see `LogoService`);
    /// a conversation with no resolvable logo simply isn't in the result.
    ///
    /// The business identity (`place_id`/`website`) is fetched in its OWN query,
    /// deliberately kept out of the main `conversations()` select and wrapped so a
    /// failure is swallowed — before the `20260712` migration adds those columns
    /// they don't exist, and this must degrade to "no logo" rather than break the
    /// inbox.
    static func resolveLogos(_ conversations: [Conversation]) async -> [UUID: URL] {
        let customerIDs = conversations.filter(\.viewerIsCustomer).map(\.id)
        guard !customerIDs.isEmpty else { return [:] }

        let rows: [LeadIdentityRow]? = try? await supabase
            .from("leads")
            .select("id, place_id, website")
            .in("id", values: customerIDs.map(\.uuidString))
            .execute()
            .value
        guard let rows, !rows.isEmpty else { return [:] }

        let byPlace = await LogoService.fetch(items: rows.compactMap { r in
            guard let pid = r.place_id, !pid.isEmpty else { return nil }
            return (placeId: pid, website: r.website)
        })
        guard !byPlace.isEmpty else { return [:] }

        var out: [UUID: URL] = [:]
        for r in rows {
            if let pid = r.place_id, let url = byPlace[pid] { out[r.id] = url }
        }
        return out
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
