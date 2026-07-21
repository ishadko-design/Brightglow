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
    /// `vehicle` is the Auto & moto filter. It matters because the same words
    /// mean different jobs on two wheels — "replace tires" is 4 units for a car
    /// and 2 (cheaper, different labor) for a bike — and the server can't infer
    /// it from the phrase.
    static func estimate(
        category: String,
        searchQuery: String,
        near coord: CLLocationCoordinate2D,
        photoDetails: String? = nil,
        vehicle: VehicleFilter? = nil
    ) async -> PriceTier? {
        // Auto & moto used to return nil here unconditionally — there was no
        // vehicle cost data, so every auto result showed "coming soon". The
        // catalog now covers all five auto categories (2026-07-20), so the
        // vertical prices like any other; the guard is gone.
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
        // An explicit filter wins; otherwise infer it, so a typed "motorcycle
        // tires" search prices as a bike even with no chip selected.
        let resolvedVehicle = vehicle
            ?? (isAutoService(category: category, searchQuery: q) ? VehicleFilter.auto : nil)
        return await EstimateService.estimate(category: resolvedCategory, description: description,
                                              zip: zip, vehicle: resolvedVehicle)
    }
}
