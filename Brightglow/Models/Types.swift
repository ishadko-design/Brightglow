import Foundation

enum Category: String, CaseIterable, Codable {
    case plumbing      = "Plumbing"
    case electrical    = "Electrical"
    case hvac          = "HVAC"
    case painting      = "Painting"
    case carpentry     = "Carpentry"
    case roofing       = "Roofing"
    case flooring      = "Flooring"
    case windowsDoors  = "Windows & Doors"

    /// Keywords a user might free-form type that map to this category.
    var keywords: [String] {
        switch self {
        case .plumbing:     return ["plumb", "tap", "faucet", "leak", "pipe", "drain", "toilet", "sink", "water heater", "sewer", "clog"]
        case .electrical:   return ["electric", "wire", "wiring", "outlet", "socket", "breaker", "panel", "light", "lighting", "fixture", "rewire", "power"]
        case .hvac:         return ["hvac", "heat", "heating", "ac", "air condition", "furnace", "thermostat", "cooling", "vent", "duct"]
        case .painting:     return ["paint", "painting", "wall color", "primer", "repaint"]
        case .carpentry:    return ["carpent", "wood", "cabinet", "shelf", "shelving", "framing", "trim", "handyman", "remodel", "deck",
                                    "chair", "armchair", "furniture", "table", "desk", "sofa", "couch", "stool", "bench", "drawer", "dresser", "seat"]
        case .roofing:      return ["roof", "roofing", "shingle", "gutter", "leak roof"]
        case .flooring:     return ["floor", "flooring", "hardwood", "tile", "laminate", "carpet", "vinyl", "lvp", "epoxy"]
        case .windowsDoors: return ["window", "door", "glass", "sash", "screen", "frame"]
        }
    }

    /// The category when the WHOLE typed term is exactly a category name or
    /// one of its keywords (e.g. "roofing", "electrical", "leak"). Returns nil
    /// for partial / multi-word phrases so we don't hijack normal typing.
    static func exactTerm(_ text: String) -> Category? {
        let q = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return allCases.first { cat in
            cat.rawValue.lowercased() == q || cat.keywords.contains(q)
        }
    }

    /// Categories whose keywords (or display name) match the free-form query.
    /// Returns all categories when the query is empty or matches nothing.
    static func matching(query: String) -> [Category] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allCases }
        let hits = allCases.filter { cat in
            cat.rawValue.lowercased().contains(q)
                || cat.keywords.contains { q.contains($0) || $0.contains(q) }
        }
        return hits.isEmpty ? allCases : hits
    }
}

extension Category {
    /// Google Places text query used to find contractors of this trade.
    var searchQuery: String {
        switch self {
        case .plumbing:     return "plumber contractor"
        case .electrical:   return "electrician contractor"
        case .hvac:         return "HVAC heating cooling contractor"
        case .painting:     return "painting contractor"
        case .carpentry:    return "carpenter contractor"
        case .roofing:      return "roofing contractor"
        case .flooring:     return "flooring contractor"
        case .windowsDoors: return "window door installation contractor"
        }
    }

    /// Indicative price tiers per trade (Places has no pricing).
    var priceTiers: [PriceTier] {
        switch self {
        case .plumbing:     return [PriceTier(label: "Minor fix", min: 100, max: 250), PriceTier(label: "Mid repair", min: 400, max: 900), PriceTier(label: "Full replacement", min: 1000, max: 3000)]
        case .electrical:   return [PriceTier(label: "Outlet / fixture", min: 80, max: 200), PriceTier(label: "Panel work", min: 400, max: 1000), PriceTier(label: "Full rewire", min: 3000, max: 8000)]
        case .hvac:         return [PriceTier(label: "Tune-up", min: 100, max: 250), PriceTier(label: "Repair", min: 300, max: 800), PriceTier(label: "Full install", min: 3000, max: 7000)]
        case .painting:     return [PriceTier(label: "Single room", min: 200, max: 600), PriceTier(label: "Full interior", min: 1500, max: 4000), PriceTier(label: "Exterior", min: 3000, max: 9000)]
        case .carpentry:    return [PriceTier(label: "Small repair", min: 150, max: 400), PriceTier(label: "Custom build", min: 800, max: 3500), PriceTier(label: "Full remodel", min: 5000, max: 15000)]
        case .roofing:      return [PriceTier(label: "Patch / repair", min: 300, max: 800), PriceTier(label: "Partial replace", min: 3000, max: 7000), PriceTier(label: "Full roof", min: 8000, max: 20000)]
        case .flooring:     return [PriceTier(label: "Single room", min: 500, max: 1500), PriceTier(label: "Whole floor", min: 2000, max: 6000), PriceTier(label: "Full home", min: 8000, max: 20000)]
        case .windowsDoors: return [PriceTier(label: "Single unit", min: 300, max: 800), PriceTier(label: "Multiple units", min: 1500, max: 4000), PriceTier(label: "Full install", min: 5000, max: 12000)]
        }
    }
}

enum Urgency: String, Codable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"
}

enum ResponseTime: String, Codable {
    case fast   = "fast"
    case normal = "normal"
    case slow   = "slow"
}

enum JobTiming: String, Codable {
    case asap      = "asap"
    case thisWeek  = "thisweek"
    case flexible  = "flexible"
}

enum QuoteStatus: String, Codable {
    case pending   = "pending"
    case responded = "responded"
    case booked    = "booked"
}

struct PriceTier: Codable, Identifiable {
    var id: String { label }
    let label: String
    let min: Int
    let max: Int
}

/// A single Google review (testimonial) shown on the contractor card.
struct Review: Codable, Identifiable {
    var id: String { author + relativeTime + String(text.prefix(16)) }
    let author: String
    let authorPhotoURL: String?
    let rating: Int
    /// Shown by default — Google's translation into the device locale when the
    /// original is in another language, otherwise the original.
    let text: String
    let relativeTime: String    // e.g. "3 weeks ago"
    /// The author's original-language text, set only when it differs from `text`
    /// (i.e. the review was translated). Drives the "See original" toggle.
    var originalText: String? = nil
    /// Localized display name of the original language (e.g. "Ukrainian"), shown
    /// in the toggle CTA. Set only when `originalText` is.
    var originalLanguageName: String? = nil
}

struct Contractor: Codable, Identifiable {
    let id: String
    let name: String
    let category: [Category]
    let city: String
    let rating: Double        // 0–5
    let reviewCount: Int
    let responseTime: ResponseTime
    let yearsActive: Int
    let photos: [String]
    let priceTiers: [PriceTier]
    let phone: String?
    let licenseNumber: String?
    let isVerified: Bool
    /// Real Google reviews (populated on the live path; empty for the snapshot).
    var reviews: [Review] = []
}

struct AIResult {
    let issue: String
    let category: Category
    let urgency: Urgency
    let priceMin: Int
    let priceMax: Int
    let notes: String
}

struct QuoteRequest: Codable, Identifiable {
    var id: String?
    let contractorId: String
    let userId: String
    let category: Category
    let description: String
    let photoUrl: String?
    let urgency: Urgency
    let timing: JobTiming
    let status: QuoteStatus
    let createdAt: Date
}
