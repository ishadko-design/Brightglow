import CoreLocation

/// Shared contractor-fetching logic used by both the List view and the Gallery
/// view, so the two screens resolve a location, query Places, and fall back to
/// the demo data identically.
enum ContractorLoader {

    /// Resolves a usable coordinate: an explicit preset (manual ZIP/city or an
    /// already-resolved fix) wins; otherwise GPS, raced against a 3s timeout so a
    /// slow/denied fix doesn't stall the screen.
    static func resolveCoordinate(
        preset: CLLocationCoordinate2D?,
        location: LocationProvider
    ) async -> CLLocationCoordinate2D? {
        if let preset { return preset }
        return await withTaskGroup(of: CLLocationCoordinate2D?.self) { group in
            group.addTask { await location.currentCoordinate() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Live Places results for the given category / free-form query near a coord.
    static func fetchLive(
        category: String,
        searchQuery: String,
        near coord: CLLocationCoordinate2D
    ) async -> [Contractor] {
        await fetchLivePage(category: category, searchQuery: searchQuery, near: coord).contractors
    }

    /// A page of live results plus the token to fetch the next page — lets a
    /// swipe-through view keep loading more contractors while content remains.
    static func fetchLivePage(
        category: String,
        searchQuery: String,
        near coord: CLLocationCoordinate2D,
        pageToken: String? = nil
    ) async -> PlacesService.Page {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return await PlacesService.fetchPage(searchText: q, near: coord, pageToken: pageToken)
        } else if let cat = Category(rawValue: category) {
            return await PlacesService.fetchPage(category: cat, near: coord, pageToken: pageToken)
        } else {
            return await PlacesService.fetchPage(searchText: "home repair", near: coord, pageToken: pageToken)
        }
    }

    /// Built-in demo contractors — used only when no location can be resolved
    /// (GPS denied / offline).
    static func fallback(category: String, searchQuery: String) -> [Contractor] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let matched = Set(Category.matching(query: q))
            return mockContractors.filter { !Set($0.category).isDisjoint(with: matched) }
        } else if !category.isEmpty {
            return mockContractors.filter { $0.category.map(\.rawValue).contains(category) }
        } else {
            return mockContractors
        }
    }

    /// Indicative local price tier for the request, used for the price line.
    static func estimate(
        category: String,
        searchQuery: String,
        near coord: CLLocationCoordinate2D,
        priceHints: [Int] = []
    ) async -> PriceTier? {
        let q   = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = !q.isEmpty
            ? (Category.matching(query: q).first ?? .plumbing)
            : (Category(rawValue: category) ?? .plumbing)
        let locality = await EstimateService.locality(for: coord)
        return await EstimateService.estimate(category: cat, job: q, locality: locality, priceHints: priceHints)
    }
}
