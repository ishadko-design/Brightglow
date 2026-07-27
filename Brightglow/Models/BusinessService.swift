import Foundation
import Supabase

/// The business side of the app: the requests (leads) addressed to a business the
/// signed-in user owns, and the editable page (`business_profiles`) behind them.
///
/// Identity is possession of the matched email — the SAME model as chat: a
/// business isn't a special account, it's an authenticated user whose verified
/// email is the `contractor_email` on some lead. So there's no bespoke auth here:
/// RLS (`owns_business`) gates every read/write to the rows that email owns.
///
/// Unlike chat replies (routed through LeadBridge so an offline party still gets
/// the email relay), a profile edit has no side effect, so these writes go DIRECT
/// to Supabase/Storage under RLS — mirroring the web portal (`site/business`).
enum BusinessService {

    // MARK: - Models

    /// One business the signed-in user can manage, plus the requests sent to it.
    struct OwnedBusiness: Identifiable, Equatable {
        let placeId: String
        let name: String
        let city: String
        let website: String
        let leads: [Conversation]
        /// Profile views over the trailing 30 days (see `business_profile_views`).
        /// A window, not a lifetime total, so the number can fall as well as rise.
        var views: Int = 0

        var id: String { placeId }
    }

    /// A service line with an indicative price range — mirrors the JSONB shape the
    /// web portal writes: `{ name, price_min, price_max, unit }`.
    struct Service: Codable, Equatable, Identifiable {
        var name: String
        var priceMin: Double?
        var priceMax: Double?
        var unit: String

        // Stable identity for SwiftUI list editing (not persisted).
        let localID = UUID()
        var id: UUID { localID }

        enum CodingKeys: String, CodingKey {
            case name
            case priceMin = "price_min"
            case priceMax = "price_max"
            case unit
        }

        init(name: String = "", priceMin: Double? = nil, priceMax: Double? = nil, unit: String = "job") {
            self.name = name; self.priceMin = priceMin; self.priceMax = priceMax; self.unit = unit
        }
    }

    /// The business-authored page. Layers over the Google-derived enrichment — any
    /// field left nil falls back to the enriched/Places value in the app. Keyed by
    /// `place_id`. Decodes tolerantly from `select("*")` (extra columns like
    /// timestamps are ignored); encodes only the owner-writable columns for upsert.
    struct BusinessProfile: Codable, Equatable {
        var placeId: String
        var displayName: String?
        var tagline: String?
        var about: String?
        var phone: String?
        var website: String?
        var services: [Service]
        var serviceArea: String?
        var licenseNumber: String?
        var licensed: Bool
        var insured: Bool
        var yearsInBusiness: Int?
        var acceptingWork: Bool
        var photos: [String]
        var logoPath: String?
        /// The owner-curated, ordered photo set (uploads + Google + website). `nil`
        /// means the business hasn't opened the photo manager yet, so the app falls
        /// back to auto-merging the sources. Non-nil (even empty) is authoritative.
        var curatedPhotos: [CuratedPhoto]?

        enum CodingKeys: String, CodingKey {
            case placeId = "place_id"
            case displayName = "display_name"
            case tagline, about, phone, website, services, licensed, insured, photos
            case serviceArea = "service_area"
            case licenseNumber = "license_number"
            case yearsInBusiness = "years_in_business"
            case acceptingWork = "accepting_work"
            case logoPath = "logo_path"
            case curatedPhotos = "curated_photos"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            placeId = try c.decode(String.self, forKey: .placeId)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            tagline = try c.decodeIfPresent(String.self, forKey: .tagline)
            about = try c.decodeIfPresent(String.self, forKey: .about)
            phone = try c.decodeIfPresent(String.self, forKey: .phone)
            website = try c.decodeIfPresent(String.self, forKey: .website)
            services = (try? c.decodeIfPresent([Service].self, forKey: .services)) ?? []
            serviceArea = try c.decodeIfPresent(String.self, forKey: .serviceArea)
            licenseNumber = try c.decodeIfPresent(String.self, forKey: .licenseNumber)
            licensed = (try? c.decodeIfPresent(Bool.self, forKey: .licensed)) ?? false
            insured = (try? c.decodeIfPresent(Bool.self, forKey: .insured)) ?? false
            yearsInBusiness = try c.decodeIfPresent(Int.self, forKey: .yearsInBusiness)
            acceptingWork = (try? c.decodeIfPresent(Bool.self, forKey: .acceptingWork)) ?? true
            photos = (try? c.decodeIfPresent([String].self, forKey: .photos)) ?? []
            logoPath = try c.decodeIfPresent(String.self, forKey: .logoPath)
            // Absent key → nil (never curated). A present `null` or `[]` both decode
            // to a definite value, which the gallery treats as authoritative.
            curatedPhotos = (try? c.decodeIfPresent([CuratedPhoto].self, forKey: .curatedPhotos)) ?? nil
        }

        /// Encode EVERY owner-writable column, writing explicit `null` for cleared
        /// fields (Swift's synthesized encoder omits nil optionals, which on an
        /// upsert-merge would leave a stale value in place instead of clearing it).
        /// Timestamps and any read-only columns are intentionally not encoded.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(placeId, forKey: .placeId)
            try c.encode(displayName, forKey: .displayName)
            try c.encode(tagline, forKey: .tagline)
            try c.encode(about, forKey: .about)
            try c.encode(phone, forKey: .phone)
            try c.encode(website, forKey: .website)
            try c.encode(services, forKey: .services)
            try c.encode(serviceArea, forKey: .serviceArea)
            try c.encode(licenseNumber, forKey: .licenseNumber)
            try c.encode(licensed, forKey: .licensed)
            try c.encode(insured, forKey: .insured)
            try c.encode(yearsInBusiness, forKey: .yearsInBusiness)
            try c.encode(acceptingWork, forKey: .acceptingWork)
            try c.encode(photos, forKey: .photos)
            try c.encode(logoPath, forKey: .logoPath)
            try c.encode(curatedPhotos, forKey: .curatedPhotos)
        }

        /// A blank page seeded from the lead — used before the business has saved
        /// anything, so the editor opens pre-filled with the known name/website.
        init(seededFrom biz: OwnedBusiness) {
            placeId = biz.placeId
            displayName = biz.name
            website = biz.website.isEmpty ? nil : biz.website
            tagline = nil; about = nil; phone = nil
            services = []
            serviceArea = nil; licenseNumber = nil
            licensed = false; insured = false; yearsInBusiness = nil; acceptingWork = true
            photos = []; logoPath = nil; curatedPhotos = nil
        }

        /// A fully empty page for a place — the editor's initial state before load.
        init(placeIdOnly placeId: String) {
            self.placeId = placeId
            displayName = nil; tagline = nil; about = nil; phone = nil; website = nil
            services = []
            serviceArea = nil; licenseNumber = nil
            licensed = false; insured = false; yearsInBusiness = nil; acceptingWork = true
            photos = []; logoPath = nil; curatedPhotos = nil
        }

        /// Tidy the page for persistence: trim text, turn blanks into nulls (so a
        /// cleared field actually clears), and drop unnamed service rows. Mirrors
        /// the web portal's `|| null` save shape.
        mutating func normalizeForSave() {
            displayName = displayName.cleaned
            tagline = tagline.cleaned
            about = about.cleaned
            phone = phone.cleaned
            website = website.cleaned
            serviceArea = serviceArea.cleaned
            licenseNumber = licenseNumber.cleaned
            services = services
                .map { var s = $0; s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines); return s }
                .filter { !$0.name.isEmpty }
        }
    }

    /// One entry in a business's curated photo list. `ref` is interpreted per
    /// `source` — see the migration (20260726000000_business_curated_photos.sql).
    /// `id` is stable across reorders so SwiftUI's ForEach / drag tracks each tile.
    struct CuratedPhoto: Codable, Equatable, Identifiable, Hashable {
        enum Source: String, Codable { case upload, google, website }
        var source: Source
        var ref: String
        var id: String { "\(source.rawValue):\(ref)" }
    }

    /// Resolve a curated entry to a loadable image URL string, or nil if it can't
    /// be formed. Uploads become a public Storage URL; Google refs are rebuilt into
    /// a Places media URL (re-attaching the API key at render time); website refs
    /// are already absolute URLs.
    static func resolvedPhotoURL(_ photo: CuratedPhoto) -> String? {
        switch photo.source {
        case .upload:  return publicURL(photo.ref)?.absoluteString
        case .website: return photo.ref
        case .google:  return PlacesService.googlePhotoMediaURL(name: photo.ref)
        }
    }

    // MARK: - Ownership / leads

    /// Businesses the signed-in user can manage, each with its requests. RLS
    /// returns leads the user is a party to; we keep only the ones addressed to
    /// them as a BUSINESS (not their own customer requests) and that carry a
    /// `place_id` (the claim/join key), then group by that key. Newest business
    /// first by most recent activity.
    static func myBusinesses() async throws -> [OwnedBusiness] {
        let session = try? await supabase.auth.session
        let myId = session?.user.id
        let myEmail = session?.user.email?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let rows: [ChatService.LeadRow] = try await supabase
            .from("leads")
            .select("id, public_id, business_name, city, status, created_at, user_id, user_email_initial, place_id, website, contractor_email, messages(id, lead_id, direction, body_text, created_at), attachments(id)")
            .order("created_at", ascending: false)
            .execute()
            .value

        var byPlace: [String: (row: ChatService.LeadRow, convos: [Conversation])] = [:]
        var order: [String] = []
        for row in rows {
            guard let placeId = row.place_id, !placeId.isEmpty else { continue }
            // A request belongs to me AS A BUSINESS when it was addressed to my
            // inbox (contractor_email == my email) — the same claim RLS uses. This
            // keeps my own outbound requests to OTHER businesses out, while still
            // including a self-test lead (my email on both sides). Always render it
            // as the business side.
            let leadEmail = row.contractor_email?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let leadEmail, let myEmail, leadEmail == myEmail else { continue }
            let convo = ChatService.makeConversation(from: row, myId: myId, viewerIsCustomerOverride: false)
            if byPlace[placeId] == nil { byPlace[placeId] = (row, []); order.append(placeId) }
            byPlace[placeId]?.convos.append(convo)
        }

        // One round trip for every owned place, not one per business. RLS already
        // limits the rows to places we own, so an empty result just means nobody
        // has looked yet — never an error worth surfacing.
        let views = await viewCounts(placeIds: order)

        return order.compactMap { placeId in
            guard let entry = byPlace[placeId] else { return nil }
            let convos = entry.convos.sorted {
                ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt)
            }
            return OwnedBusiness(
                placeId: placeId,
                name: entry.row.business_name ?? "Your business",
                city: entry.row.city ?? "",
                website: entry.row.website ?? "",
                leads: convos,
                views: views[placeId] ?? 0
            )
        }
    }

    /// Trailing-30-day view totals per place. The dashboard tile is decoration on
    /// top of the real work (requests), so a failure here degrades to zero rather
    /// than failing the whole dashboard load.
    private static func viewCounts(placeIds: [String]) async -> [String: Int] {
        guard !placeIds.isEmpty else { return [:] }
        struct Row: Decodable { let place_id: String; let views: Int }
        let since = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let sinceDay = fmt.string(from: since)
        do {
            let rows: [Row] = try await supabase
                .from("business_profile_views")
                .select("place_id, views")
                .in("place_id", values: placeIds)
                .gte("day", value: sinceDay)
                .execute()
                .value
            return rows.reduce(into: [:]) { $0[$1.place_id, default: 0] += $1.views }
        } catch {
            #if DEBUG
            print("👁 view counts failed: \(error)")
            #endif
            return [:]
        }
    }

    /// Record that someone opened a business's page. Fire-and-forget: the caller
    /// must never wait on it, and a failure must never surface to the customer.
    /// Deliberately stores no viewer identity — see the migration for why.
    static func recordView(placeId: String) async {
        guard !placeId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await supabase
                .rpc("record_business_view", params: ["p_place_id": placeId])
                .execute()
        } catch {
            #if DEBUG
            print("👁 recordView failed: \(error)")
            #endif
        }
    }

    // MARK: - Profile read / write

    /// The saved page for a place, or nil if the business hasn't created one yet.
    static func profile(placeId: String) async throws -> BusinessProfile? {
        let rows: [BusinessProfile] = try await supabase
            .from("business_profiles")
            .select("*")
            .eq("place_id", value: placeId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Owner-uploaded work-photo URLs for a set of businesses, keyed by place_id —
    /// only places that have saved photos appear. One `.in` query: most place_ids
    /// have no `business_profiles` row, so the result is just the claimed few. Used
    /// to lead the consumer list/gallery with a business's OWN curated photos ahead
    /// of Google's. Best-effort — any failure returns [:] and the caller falls back
    /// to Google/website photos.
    static func uploadedPhotoURLs(placeIds: [String]) async -> [String: [String]] {
        let ids = placeIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [:] }
        struct Row: Decodable { let place_id: String; let photos: [String]? }
        do {
            let rows: [Row] = try await supabase
                .from("business_profiles")
                .select("place_id, photos")
                .in("place_id", values: ids)
                .execute()
                .value
            var out: [String: [String]] = [:]
            for row in rows {
                let urls = (row.photos ?? []).compactMap { publicURL($0)?.absoluteString }
                if !urls.isEmpty { out[row.place_id] = urls }
            }
            return out
        } catch {
            #if DEBUG
            print("🏢 uploadedPhotoURLs failed: \(error)")
            #endif
            return [:]
        }
    }

    /// Single-business convenience (the gallery / preview path).
    static func uploadedPhotoURLs(placeId: String) async -> [String] {
        await uploadedPhotoURLs(placeIds: [placeId])[placeId] ?? []
    }

    /// Upsert the owner-writable columns. RLS (`owns_business`) rejects a write to
    /// a place the caller doesn't own, so a not-mine edit fails server-side rather
    /// than here.
    static func saveProfile(_ profile: BusinessProfile) async throws {
        try await supabase
            .from("business_profiles")
            .upsert(profile, onConflict: "place_id")
            .execute()
    }

    // MARK: - Storage (logo + photos)

    private static let bucket = "business-photos"

    /// Upload image bytes to `<place_id>/[prefix-]<uuid>.<ext>` and return the
    /// stored object path (what the DB row holds). Storage RLS confirms ownership
    /// by the first path segment.
    static func uploadImage(
        _ data: Data, contentType: String, placeId: String, prefix: String = ""
    ) async throws -> String {
        let ext = ext(for: contentType)
        let head = prefix.isEmpty ? "" : "\(prefix)-"
        let path = "\(placeId)/\(head)\(UUID().uuidString).\(ext)"
        try await supabase.storage.from(bucket).upload(
            path,
            data: data,
            options: FileOptions(cacheControl: "31536000", contentType: contentType, upsert: false)
        )
        return path
    }

    /// Public CDN URL for a stored object path (the bucket is public-read).
    static func publicURL(_ path: String) -> URL? {
        try? supabase.storage.from(bucket).getPublicURL(path: path)
    }

    private static func ext(for contentType: String) -> String { fileExtension(for: contentType) }

    static func fileExtension(for contentType: String) -> String {
        switch contentType.lowercased() {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default: return "jpg"
        }
    }

    /// Sniff the image type from the leading bytes so an upload's Content-Type is
    /// right (the buckets accept png/jpeg/webp). Defaults to JPEG. Shared by the
    /// business editor's logo/photo uploads and the consumer profile's avatar.
    static func imageContentType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 2, bytes[0] == 0x89, bytes[1] == 0x50 { return "image/png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "image/jpeg" }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 { return "image/webp" }
        return "image/jpeg"
    }

    // MARK: - Completeness

    /// Profile-readiness score over the fields the native Settings editor exposes
    /// (logo, name, description, photos, at least one priced service) — the same
    /// five things the dashboard's "Profile readiness" card nudges toward. Returns
    /// a 0…1 fraction.
    static func completeness(_ p: BusinessProfile) -> Double {
        let checks: [Bool] = [
            !(p.displayName ?? "").isEmpty,
            !(p.about ?? "").isEmpty,
            !(p.logoPath ?? "").isEmpty,
            !p.photos.isEmpty,
            p.services.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty },
        ]
        let done = checks.filter { $0 }.count
        return Double(done) / Double(checks.count)
    }

    static func isComplete(_ p: BusinessProfile) -> Bool { completeness(p) >= 1.0 }

    // MARK: - Trade templates

}

private extension Optional where Wrapped == String {
    /// Trimmed, or nil when empty/whitespace — for turning a blank field into a
    /// null column on save.
    var cleaned: String? {
        let t = (self ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
