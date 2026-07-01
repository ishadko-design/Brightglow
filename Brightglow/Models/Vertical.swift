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
    if autoCategoryItems.contains(where: { $0.name == category || $0.searchQuery == searchQuery }) {
        return true
    }
    let q = searchQuery.lowercased()
    guard !q.isEmpty else { return false }
    return autoCategoryItems.contains { $0.keywords.contains { q.contains($0) } }
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
}
