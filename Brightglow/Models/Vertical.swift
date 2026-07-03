import Foundation

/// Top-level service vertical shown on the landing sheet. Each opens its own
/// category grid; tapping a category drills into the contractor flow.
/// Declaration order = on-screen order (Auto left, Home right per Figma).
enum Vertical: String, CaseIterable, Identifiable {
    case auto = "Auto and moto"
    case home = "Home"

    var id: String { rawValue }

    /// Asset-catalog image for the landing card.
    var assetName: String {
        switch self {
        case .auto: return "fig_vertical_auto"
        case .home: return "fig_vertical_home"
        }
    }
}

/// A service category inside the Auto & moto vertical. Unlike the home
/// `Category` enum, these route to Google Places purely through `searchQuery`,
/// so they stay out of `Category` (and therefore out of the home photo
/// classifier, which must keep offering home trades only).
/// Which vehicle type the Auto & moto results are filtered to.
enum VehicleFilter: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case moto = "Moto"
    var id: String { rawValue }
}

struct AutoCategory: Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    /// Google Places text query for CAR providers of this service (default).
    let searchQuery: String
    /// Google Places text query for MOTORCYCLE providers of this service.
    let motoSearchQuery: String
    /// Asset-catalog image for the grid card (blank → fallback colour for now).
    let assetName: String
    /// Vision/label tokens used to recognise this service from a photo (on-device
    /// fallback) and to map a vision-LLM reply back to the category.
    let keywords: [String]

    /// The Places query for the selected vehicle filter.
    func query(for vehicle: VehicleFilter) -> String {
        vehicle == .moto ? motoSearchQuery : searchQuery
    }
}

/// Launch set for Auto & moto — five highest-demand services. "Repair" folds in
/// routine maintenance/oil changes and battery/electrical work (same general
/// repair shops), per product decision.
let autoCategoryItems: [AutoCategory] = [
    AutoCategory(name: "Repair",               searchQuery: "auto repair and maintenance shop",  motoSearchQuery: "motorcycle repair and maintenance shop", assetName: "fig_auto_repair",
                 keywords: ["repair", "engine", "mechanic", "brake", "transmission", "motor", "garage", "muffler", "exhaust", "suspension", "oil change", "maintenance", "car", "vehicle", "motorcycle", "automobile", "truck", "sedan", "engine bay"]),
    AutoCategory(name: "Tires",                searchQuery: "tire shop",                          motoSearchQuery: "motorcycle tire shop",                   assetName: "fig_auto_tires",
                 keywords: ["tire", "tyre", "wheel", "rim", "flat tire", "tread", "alloy wheel", "puncture"]),
    AutoCategory(name: "Cleaning & Detailing", searchQuery: "car wash and auto detailing",        motoSearchQuery: "motorcycle detailing",                   assetName: "fig_auto_detailing",
                 keywords: ["detailing", "car wash", "polish", "wax", "ceramic coating", "vacuum", "car interior", "upholstery"]),
    AutoCategory(name: "Body & Paint",         searchQuery: "auto body and paint shop",           motoSearchQuery: "motorcycle paint and custom shop",       assetName: "fig_auto_body",
                 keywords: ["dent", "scratch", "bumper", "fender", "collision", "body panel", "respray", "bodywork", "car paint", "rust"]),
    AutoCategory(name: "Glass",                searchQuery: "auto glass and windshield repair",   motoSearchQuery: "motorcycle windscreen and parts shop",   assetName: "fig_auto_glass",
                 keywords: ["windshield", "windscreen", "auto glass", "car window", "windshield chip", "windshield crack"]),
]

/// True when a results query targets an Auto & moto service. Photo screening
/// uses this to KEEP vehicle photos (the actual work) instead of rejecting them
/// the way it does for home trades.
func isAutoService(category: String, searchQuery: String) -> Bool {
    if autoCategoryItems.contains(where: { $0.name == category }) { return true }
    return AutoCategory.matching(query: searchQuery) != nil
}

/// Shown in place of a price line whenever there's no real, verifiable
/// number to show — auto/moto always (no comparable data source to the home
/// pricing engine exists yet — a vehicle repair estimate needs a labor-time
/// guide + parts pricing, not building permits, so it's a separate build),
/// or a home job the pricing engine doesn't cover and that has no real
/// review-derived range either. Shows a genuine count (businesses actually
/// found nearby) instead of a synthesized guess — there is no LLM fallback
/// left in this app; every price line is either real data or this.
func priceComingSoonText(businessCount: Int, includeCount: Bool = true) -> String {
    guard includeCount else { return "Price estimate coming soon" }
    guard businessCount > 0 else { return "Price estimate: Coming soon" }
    return "\(businessCount) business\(businessCount == 1 ? "" : "es") nearby — price estimate coming soon"
}

extension AutoCategory {
    /// The auto service a free-form query is about, or nil when the query isn't
    /// vehicle work. Prefers the most specific keyword hit ("car paint" beats
    /// "car") so "car painting" resolves to Body & Paint, not general Repair.
    static func matching(query: String) -> AutoCategory? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let exact = autoCategoryItems.first(where: {
            $0.searchQuery.lowercased() == q || $0.motoSearchQuery.lowercased() == q
        }) { return exact }
        let scored: [(AutoCategory, Int)] = autoCategoryItems.compactMap { item in
            item.keywords.filter { q.contains($0) }.map(\.count).max().map { (item, $0) }
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }
}

/// A photo classification result: a Home trade or an Auto & moto service. Keeps
/// the two verticals' category types distinct while giving the capture flow one
/// value to prefill, tag, and route on.
enum TradeMatch: Equatable, Hashable {
    case home(Category)
    case auto(AutoCategory)

    /// Display name — used for the prefill term and selectable tag.
    var label: String {
        switch self {
        case .home(let c): return c.rawValue
        case .auto(let a): return a.name
        }
    }

    /// True when this is an Auto & moto service (vs a home trade).
    var isAuto: Bool { if case .auto = self { return true }; return false }
}
