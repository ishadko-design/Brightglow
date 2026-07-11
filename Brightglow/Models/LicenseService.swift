import Foundation

/// Contractor licence lookups via the Supabase `licenses` Edge Function, backed
/// by the CSLB (California Contractors State License Board) public licence
/// master — see `supabase/migrations/*_cslb_licenses.sql`.
///
/// Businesses are matched by PHONE: Google Places gives us `nationalPhoneNumber`
/// and 99.9% of CSLB rows carry a business phone, so an exact normalized-digit
/// match avoids fuzzy name/address matching entirely.
///
/// **A missing result means "unknown", never "unlicensed."** CSLB covers
/// California only, a business may be filed under a different phone, and the
/// call is best-effort (any failure returns empty). So the UI shows a badge when
/// a licence is found and shows *nothing* otherwise — it must never claim a
/// business is unlicensed.
enum LicenseService {
    private static let ref: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
    private static let anonKey: String =
        (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""
    private static let appToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "APP_TOKEN") as? String) ?? ""
    static var isConfigured: Bool { !ref.isEmpty && !anonKey.isEmpty }

    /// An active licence: not suspended, not past expiry (enforced server-side).
    struct License {
        let licenseNo: String
        /// Raw CSLB classification codes, e.g. "B| C10| C36". Kept for a future
        /// tightening of the badge (matching the trade being searched).
        let classifications: String?
    }

    /// Exactly 10 digits, or nil — must match the importer + Edge Function.
    static func normalizePhone(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        if digits.count == 10 { return digits }
        if digits.count == 11, digits.hasPrefix("1") { return String(digits.dropFirst()) }
        return nil
    }

    /// Active licences for the given businesses, keyed by contractor id. Only
    /// contractors with a usable phone are looked up; the rest simply don't
    /// appear in the result (unknown, not unlicensed).
    static func fetch(for contractors: [Contractor]) async -> [String: License] {
        // Map normalized phone → the contractor ids sharing it (chains reuse one
        // number), so a single licence can badge every branch it belongs to.
        var idsByPhone: [String: [String]] = [:]
        for c in contractors {
            guard let phone = normalizePhone(c.phone) else { continue }
            idsByPhone[phone, default: []].append(c.id)
        }
        let phones = Array(idsByPhone.keys)

        guard isConfigured, !phones.isEmpty,
              let url = URL(string: "https://\(ref).supabase.co/functions/v1/licenses")
        else { return [:] }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        if !appToken.isEmpty { req.setValue(appToken, forHTTPHeaderField: "x-app-token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["phones": phones])

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(FetchResponse.self, from: data)
        else { return [:] }

        var out: [String: License] = [:]
        for (phone, entry) in decoded.licenses {
            for id in idsByPhone[phone] ?? [] {
                out[id] = License(licenseNo: entry.licenseNo, classifications: entry.classifications)
            }
        }
        return out
    }

    private struct FetchResponse: Decodable { let licenses: [String: Entry] }
    private struct Entry: Decodable {
        let licenseNo: String
        let classifications: String?
    }
}
