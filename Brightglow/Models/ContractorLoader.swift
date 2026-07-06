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
    /// Real data only — nationwide regional cost data, cross-checked against
    /// SF permits where covered — nil (no synthesized guess, no noisy
    /// review-mention range) when it has nothing, including always for
    /// auto/moto (no pricing data source exists for it yet) and Mold & Pest
    /// Control (no cost data source covers it).
    ///
    /// `category` is always forwarded now — previously this only sent
    /// `searchQuery`/`photoDetails`, so a plain category tap (the most common
    /// path: no typed search, no photo) built an empty job description and
    /// silently never priced anything, for any category. The server
    /// classifies the specific job from `category` + this description.
    ///
    /// `photoDetails` (size/capacity/material extracted from the captured
    /// photo, e.g. "40 gallon, tankless") is appended to the description
    /// sent to the pricing engine only — it never changes what businesses
    /// get searched.
    static func estimate(
        category: String,
        searchQuery: String,
        near coord: CLLocationCoordinate2D,
        photoDetails: String? = nil
    ) async -> PriceTier? {
        guard !isAutoService(category: category, searchQuery: searchQuery) else { return nil }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = [q, photoDetails]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        // A free-text query without a chip leaves `category` empty. Recover
        // one when the text is exactly a category term (cheap, unambiguous);
        // otherwise send it empty — the server classifies the job from the
        // description, which the client can't do from a multi-word phrase.
        let resolvedCategory = category.isEmpty ? (Category.exactTerm(q)?.rawValue ?? "") : category
        let (_, zip) = await EstimateService.geocode(for: coord)
        return await EstimateService.estimate(category: resolvedCategory, description: description, zip: zip)
    }
}
