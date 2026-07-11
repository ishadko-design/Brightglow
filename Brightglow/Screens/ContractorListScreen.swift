import SwiftUI
import CoreLocation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractorListScreen
//
// Sits between the main screen and the gallery. Contractors are shown as a
// vertically-scrolling list; each row carries a horizontally-scrolling strip of
// that contractor's screened work photos. Tapping any photo opens the gallery
// view for that contractor.
//
// Data is loaded and photos screened with the same logic as the gallery (via the
// shared `ContractorLoader` + `PhotoFilter`), so the two screens stay in step.
// The already-screened set is handed to the gallery on tap, so it doesn't
// re-fetch or re-screen.
// ─────────────────────────────────────────────────────────────────────────────

struct ContractorListScreen: View {
    var category: String = ""
    var searchQuery: String = ""
    var aiResult: AIResult? = nil
    /// When set (manual ZIP/city or an already-resolved fix), used instead of GPS.
    var presetCoordinate: CLLocationCoordinate2D? = nil
    /// Photos the user attached before arriving here (camera capture + drawing,
    /// or the search bar's own picker) — carried to the quote-request screen.
    var attachedImages: [UIImage] = []
    /// Cost-relevant attributes extracted from the captured photo (size,
    /// capacity, material — e.g. "40 gallon, tankless"), if any. Narrows the
    /// price estimate only — never used for the business search.
    var photoDetails: String? = nil
    /// Chat-refined business-search phrase (`search_terms`). For home searches
    /// it overrides the Places query so the clarifying chat actually narrows the
    /// match; if it finds nothing we fall back to `searchQuery` so narrowing
    /// never empties results. Ignored for auto (the vehicle toggle governs that).
    var businessSearchOverride: String = ""
    /// What a matching work photo shows (`photo_terms`) — ranks each business's
    /// screened photos so "did a similar job" leads. Falls back to the query.
    var photoMatchTerms: String = ""
    /// Whether a real price is expected (a home trade the engine covers). False
    /// for auto/moto and uncovered categories → the price line shows the
    /// match-only "coming soon" state instead of attempting a number.
    var priceable: Bool = true

    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var location = LocationProvider()

    @State private var contractors: [Contractor] = []
    /// Screened work-photo URLs per contractor id. A contractor only appears in
    /// the list once it has a non-nil entry; an empty result drops it entirely
    /// (mirrors the gallery's no-work-photos handling).
    @State private var screenedByID: [String: [String]] = [:]
    /// Contractors whose photos are mid-screening (dedupe lazy per-row screening).
    @State private var screening: Set<String> = []
    /// How many of each contractor's source photos have been screened so far
    /// (lets a re-scan resume where the last one stopped).
    @State private var scannedCount: [String: Int] = [:]
    /// Captured from the live fetch so the gallery can keep paginating this search.
    @State private var nextPageToken: String? = nil
    @State private var resolvedCoord: CLLocationCoordinate2D? = nil
    @State private var isLoading   = false
    @State private var estimate: PriceTier? = nil

    /// The business whose "Get quote" was tapped — drives the quote screen.
    /// Figma 765:13844 moved the CTA from a floating bar into each row, so the
    /// request now targets that specific business rather than the top-ranked one.
    /// Held by id (not the value) because `navigationDestination(item:)` wants a
    /// Hashable, and `Contractor` isn't one.
    @State private var quoteContractorID: String? = nil
    /// Explainer for the header's info icon next to the estimate.
    @State private var showEstimateInfo = false
    @State private var goGallery = false
    @State private var startContractorID: String? = nil
    /// Which photo in the tapped contractor's strip was tapped — the gallery
    /// opens on that exact shot.
    @State private var startPhotoIndex: Int = 0
    /// The contractor the gallery is currently showing — used to scroll the list
    /// back to that exact spot when the user returns (they may have skipped past
    /// the one they opened).
    @State private var lastViewedID: String? = nil
    /// Auto & moto only: which vehicle type to show (defaults to cars).
    @State private var vehicle: VehicleFilter = .auto
    /// Contractors whose rows have actually scrolled into view — gates photo
    /// loading so an off-screen business costs nothing until the user reaches it.
    @State private var revealedIDs: Set<String> = []
    /// Places loaded from a cached/shared verdict that wasn't rich-tagged yet —
    /// enriched once when their row is first revealed (consumed on use), so we
    /// pay the vision cost lazily per scrolled row, not for the whole list at once.
    @State private var needsEnrich: Set<String> = []
    /// Kept work photos + their scene labels per contractor (the source of truth);
    /// `screenedByID` is this list ordered by the current query for display.
    @State private var keptPhotos: [String: [ScreenedPhoto]] = [:]
    /// Active contractor licences (CSLB), by contractor id. Absence means
    /// "unknown" — CSLB is California-only — never "unlicensed", so a missing
    /// entry shows no badge rather than a negative one.
    @State private var licenseByID: [String: LicenseService.License] = [:]
    /// How many of the (relevance-ranked) contractors are shown. Starts at the
    /// best-matching `initialVisibleCount`; "See more" reveals the rest.
    @State private var visibleLimit = initialVisibleCount
    /// True while "See more" is fetching another page from Places.
    @State private var isLoadingMore = false

    private var headerTitle: String {
        // Auto & moto: a friendly vehicle-aware title ("Auto repair"), never the
        // raw Places query ("auto repair and maintenance shop").
        if let auto = autoCategory {
            return "\(vehicle.rawValue) \(auto.name.lowercased())"
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
    }

    /// The Auto & moto category being viewed, if any (drives the vehicle filter).
    private var autoCategory: AutoCategory? { autoCategoryItems.first { $0.name == category } }

    /// Query actually sent to Places — the moto variant when the filter is on
    /// Moto, else the chat's refined `search_terms` when present, else the raw
    /// query. (The auto vehicle toggle owns the query for auto services, so the
    /// override only applies to home searches.)
    private var effectiveSearchQuery: String {
        if let auto = autoCategory { return auto.query(for: vehicle) }
        let override = businessSearchOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? searchQuery : override
    }

    /// What the user actually typed, if anything — auto categories carry a
    /// synthetic Places query in `searchQuery`, which must never pre-fill the
    /// quote-request text.
    private var typedQuery: String {
        autoCategory == nil ? searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// Term source for photo ordering — the chat's `photo_terms` when present (a
    /// direct description of a matching work photo), else the live query, else
    /// the category, so a plain category browse still leads with its best photos.
    private var orderQuery: String {
        let terms = photoMatchTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { return terms }
        return effectiveSearchQuery.isEmpty ? category : effectiveSearchQuery
    }

    /// The rows actually rendered — the top `visibleLimit` of the ranked list.
    /// (`contractors` is already sorted best-match-first by PlacesService's
    /// relevance ranking, so a prefix IS the best-matching set.)
    private var visibleContractors: [Contractor] {
        Array(contractors.prefix(visibleLimit))
    }

    /// More to show: either already-fetched businesses held back by the limit, or
    /// another page still available from Places.
    private var hasMore: Bool {
        contractors.count > visibleLimit || nextPageToken != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top

            ZStack(alignment: .top) {
                AppColors.bg.ignoresSafeArea()

                if isLoading && contractors.isEmpty {
                    statusView(spinner: true, text: "Finding businesses near you")
                } else if contractors.isEmpty {
                    notFoundView
                } else {
                    // Text loads in full immediately; photos stream in per row.
                    list(bottomInset: proxy.safeAreaInsets.bottom)
                }

                header(topInset: topInset)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .task { await load() }
        // Switching Auto ⇄ Moto re-runs the search for the other vehicle type.
        .onChange(of: vehicle) { _, _ in Task { await reload() } }
        .navigationDestination(isPresented: $goGallery) {
            ContractorGalleryScreen(
                category: category,
                // The effective (auto/moto) query so the gallery paginates the same
                // search the user is viewing.
                searchQuery: effectiveSearchQuery,
                aiResult: aiResult,
                presetCoordinate: resolvedCoord ?? presetCoordinate,
                preloadedContractors: contractors,
                preScreened: screenedByID,
                startContractorID: startContractorID,
                startPhotoIndex: startPhotoIndex,
                initialPageToken: nextPageToken,
                lastViewedID: $lastViewedID,
                attachedImages: attachedImages
            )
        }
        .navigationDestination(item: $quoteContractorID) { id in
            // Same consent/review step the gallery uses, aimed at the business
            // whose row CTA was tapped.
            QuoteRequestScreen(
                contractor: contractors.first { $0.id == id },
                requestSummary: typedQuery,
                initialImages: attachedImages
            )
        }
        .alert("How we estimate", isPresented: $showEstimateInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A typical price range for this job in your area. The business gives you the final quote.")
        }
    }

    // ── Scrollable list of contractor rows ────────────────────────────────────
    // Figma 444:1275 — blocks stacked with a 24pt gap.
    private func list(bottomInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 24) {
                    ForEach(visibleContractors) { contractor in
                        ContractorListRow(
                            contractor: contractor,
                            // Photos load only once the row is actually on screen
                            // (revealed); until then it shows gray placeholders — so
                            // fetching a 20-business list only downloads photos for
                            // the ~4 businesses in view, then more as the user scrolls.
                            photos: revealedIDs.contains(contractor.id) ? screenedByID[contractor.id] : nil,
                            isLicensed: licenseByID[contractor.id] != nil,
                            onOpen: { photoIndex in open(contractor, photoIndex: photoIndex) },
                            onReviews: { openReviews(for: contractor) },
                            onQuote: { quoteContractorID = contractor.id }
                        )
                        .id(contractor.id)
                        // Strictly lazy: reveal (and screen) a row's photos only when
                        // it genuinely scrolls into view — not LazyVStack's render buffer.
                        .onScrollVisibilityChange(threshold: 0.05) { visible in
                            guard visible, !revealedIDs.contains(contractor.id) else { return }
                            revealedIDs.insert(contractor.id)
                            Task { await screenIfNeeded(contractor) }
                            Task { await enrichIfNeeded(contractor) }
                        }
                    }

                    if hasMore { seeMoreButton }
                }
                // Clears the header bar (~64pt) + a 12pt gap. The ScrollView
                // already starts below the safe area, so topInset is NOT added
                // here (doing so double-counts it and leaves a large gap).
                // Clears the taller two-row header (~93pt) + a small gap.
                .padding(.top, 96 + 12)
                // Just the home indicator + a small breathing gap under the last row.
                .padding(.bottom, bottomInset + 24)
            }
            // On returning from the gallery, jump to whichever contractor the user
            // left off on so the list resumes at that exact spot.
            .onChange(of: goGallery) { _, isOpen in
                guard !isOpen, let id = lastViewedID else { return }
                // Defer a tick so the list is re-laid-out after the pop before we
                // scroll, otherwise the lazy row may not exist to scroll to yet.
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // ── "See more" — reveals the businesses held back below the top matches ───
    private var seeMoreButton: some View {
        Button(action: { Task { await showMore() } }) {
            Group {
                if isLoadingMore {
                    ProgressView().tint(.white)
                } else {
                    Text("See more")
                        .font(.h4)
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            .secondaryButtonBackground()
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMore)
        .padding(.top, 8)
    }

    // ── Auto/Moto segmented filter (pill) ─────────────────────────────────────
    private var vehicleFilter: some View {
        HStack(spacing: 2) {
            ForEach(VehicleFilter.allCases) { v in
                Text(v.rawValue)
                    .font(.bodySmall)
                    .fontWeight(.semibold)
                    .foregroundStyle(vehicle == v ? AppColors.bg : .white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .background { if vehicle == v { Capsule().fill(.white) } }
                    .contentShape(Capsule())
                    .onTapGesture {
                        if vehicle != v { withAnimation(.easeInOut(duration: 0.15)) { vehicle = v } }
                    }
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.12)))
        .fixedSize()
    }

    // ── Header — matches the gallery / main screen top bar ────────────────────
    private func header(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1 — back button + full-width title (edge to edge).
            HStack(alignment: .center, spacing: 4) {
                Button(action: { dismiss() }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(headerTitle)
                    .font(.h2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Row 2 — Auto & moto categories show ONLY the Auto ⇄ Moto filter,
            // left-aligned (no business count / estimate / description). Home
            // categories show the estimate + info affordance when there's a real
            // range — and nothing at all when there isn't.
            if !contractors.isEmpty {
                if autoCategory != nil {
                    vehicleFilter
                        .padding(.leading, 16)
                } else if let tier = estimate {
                    HStack(alignment: .center, spacing: 4) {
                        Text("Est prices: $\(money(tier.min))–\(money(tier.max))")
                            .font(.bodySmall)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Button(action: { showEstimateInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(alignment: .top) { BlurredHeaderBackground() }
    }

    private func statusView(spinner: Bool, text: String) -> some View {
        VStack(spacing: 16) {
            if spinner { ProgressView().tint(.white).scaleEffect(1.4) }
            Text(text)
                .font(.h3)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notFoundView: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AppColors.textSecondary)
            Text("No contractors found in this area")
                .font(.h3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Try a different location or category.")
                .font(.bodySmall)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: { dismiss() }) {
                Text("Change location")
                    .font(.h4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                    .secondaryButtonBackground()
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    private func open(_ contractor: Contractor, photoIndex: Int = 0) {
        startContractorID = contractor.id
        startPhotoIndex = photoIndex
        goGallery = true
    }

    private func openReviews(for contractor: Contractor) {
        if let url = URL(string: "https://search.google.com/local/reviews?placeid=\(contractor.id)") {
            openURL(url)
        }
    }

    /// Reveal everything already fetched; if the limit has caught up with the
    /// fetched set, pull the next Places page instead. Photos still load lazily
    /// per row, so revealing rows costs nothing until the user scrolls to them.
    @MainActor
    private func showMore() async {
        guard !isLoadingMore else { return }

        if contractors.count > visibleLimit {
            withAnimation(.easeInOut(duration: 0.2)) { visibleLimit = contractors.count }
            return
        }

        guard let token = nextPageToken, let coord = resolvedCoord else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let page = await ContractorLoader.fetchLivePage(
            category: category, searchQuery: effectiveSearchQuery, near: coord, pageToken: token)
        let existing = Set(contractors.map(\.id))
        let fresh = page.contractors.filter { !existing.contains($0.id) }
        nextPageToken = page.nextPageToken
        guard !fresh.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            contractors.append(contentsOf: fresh)
            visibleLimit = contractors.count
        }
        await loadLicenses(for: fresh)
    }

    // ── Data loading + progressive photo screening ────────────────────────────
    @MainActor
    private func load() async {
        guard contractors.isEmpty else { return }
        isLoading = true

        let resolved = await ContractorLoader.resolveCoordinate(
            preset: presetCoordinate, location: location)

        var query = effectiveSearchQuery
        if let coord = resolved {
            var page = await ContractorLoader.fetchLivePage(
                category: category, searchQuery: query, near: coord)
            // Zero-result safeguard: a chat-refined query that finds nothing
            // falls back to the user's raw query, so narrowing the search can
            // never blank the results.
            let base = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if page.contractors.isEmpty, !base.isEmpty, base != query {
                query = base
                page = await ContractorLoader.fetchLivePage(
                    category: category, searchQuery: query, near: coord)
            }
            contractors = page.contractors
            nextPageToken = page.nextPageToken
            resolvedCoord = coord
            // Reuse verdicts from a previous launch so businesses screened before
            // show their photos immediately without re-downloading the pool.
            let allowVehicles = isAutoService(category: category, searchQuery: query)
            for c in contractors {
                guard let v = ScreeningStore.shared.get(c.id, allowVehicles: allowVehicles) else { continue }
                if !v.kept.isEmpty {
                    // Cached work photos → show them, ordered by the current query.
                    keptPhotos[c.id] = v.kept
                    screenedByID[c.id] = PhotoFilter.order(v.kept, query: orderQuery)
                    scannedCount[c.id] = v.scanned
                    // A verdict cached before rich tagging (or by an older build)
                    // orders only on generic labels — enrich it when its row shows.
                    if !v.enriched { needsEnrich.insert(c.id) }
                } else if v.scanned >= c.photos.count {
                    // Whole pool scanned, no work photos → mark scanned (skip
                    // re-screening); dropped just below. A *partial* empty verdict
                    // is left unprimed so the row re-scans deeper this time.
                    scannedCount[c.id] = v.scanned
                }
            }
            // Pull shared verdicts for anything not already known locally, so a
            // place screened by ANY other user is reused here without re-screening.
            let unknownIDs = contractors.map(\.id).filter { scannedCount[$0] == nil }
            let remote = await VerdictService.fetch(ids: unknownIDs, allowVehicles: allowVehicles)
            for (id, v) in remote {
                scannedCount[id] = v.scanned
                if !v.kept.isEmpty {
                    keptPhotos[id] = v.kept
                    screenedByID[id] = PhotoFilter.order(v.kept, query: orderQuery)
                    if !v.enriched { needsEnrich.insert(id) }
                }
                ScreeningStore.shared.save(id, allowVehicles: allowVehicles,
                                           kept: v.kept, scanned: v.scanned, enriched: v.enriched)
            }

            // Drop businesses confirmed to have no work photos in their whole pool,
            // so they don't reappear as blank rows on a later visit.
            contractors.removeAll { c in
                (scannedCount[c.id] ?? 0) >= c.photos.count && (screenedByID[c.id]?.isEmpty ?? true)
            }
            // Only chase a price for a covered home trade. Auto/moto and
            // uncovered categories are match-only — the price line shows the
            // "coming soon" state (with a real business count) instead.
            if !contractors.isEmpty && priceable {
                Task { @MainActor in
                    estimate = await ContractorLoader.estimate(
                        category: category, searchQuery: query, near: coord,
                        photoDetails: photoDetails)
                }
            }
        } else {
            contractors = ContractorLoader.fallback(
                category: category, searchQuery: query)
        }
        isLoading = false
        // Photos are screened lazily per row (see `screenIfNeeded`) so we only pay
        // for the businesses the user actually scrolls to.
        await loadLicenses(for: contractors)
    }

    /// Look up active contractor licences for businesses we haven't checked yet.
    /// One batched call; best-effort, so a failure simply leaves the badges off.
    @MainActor
    private func loadLicenses(for batch: [Contractor]) async {
        let unknown = batch.filter { licenseByID[$0.id] == nil }
        guard !unknown.isEmpty else { return }
        let found = await LicenseService.fetch(for: unknown)
        guard !found.isEmpty else { return }
        licenseByID.merge(found) { _, new in new }
    }

    /// Re-run the search from scratch (used when the Auto ⇄ Moto filter changes).
    private func reload() async {
        contractors = []
        screenedByID = [:]
        keptPhotos = [:]
        scannedCount = [:]
        revealedIDs = []
        needsEnrich = []
        nextPageToken = nil
        estimate = nil
        licenseByID = [:]
        visibleLimit = initialVisibleCount
        await load()
    }

    /// Lazily screen one contractor's photos when its row appears (LazyVStack only
    /// renders visible rows), so we issue Places Photo requests only for businesses
    /// the user scrolls to. The list pass is cheap: scan a few photos, keep a few —
    /// the full pool is screened later in the gallery if the business is opened.
    /// First strip fill — runs once when the row scrolls into view. Keeps scanning
    /// deeper into the pool until ~4 work photos are found (or the pool is
    /// exhausted), so a business whose first few photos are logos/people/blurry
    /// still shows its work shots instead of a blank strip. Scroll-to-load-more
    /// then grows it beyond these four.
    /// `@MainActor` so the `@State` writes resume on the main actor after the
    /// off-main screening work — otherwise SwiftUI doesn't observe the update and
    /// the photos only appear after the screen is rebuilt (reopening the category).
    @MainActor
    private func screenIfNeeded(_ c: Contractor) async {
        guard scannedCount[c.id] == nil, !screening.contains(c.id) else { return }
        screening.insert(c.id)
        defer { screening.remove(c.id) }

        // Accumulate locally and leave `screenedByID[c.id]` nil until done, so the
        // row shows placeholders (not a blank strip) while scanning. Scan deeper
        // into the pool if early photos are rejected, so a business whose first
        // shots are logos/people still surfaces its work photos.
        let allowVehicles = isAutoService(category: category, searchQuery: effectiveSearchQuery)
        var kept: [ScreenedPhoto] = []
        var scanned = 0
        while kept.count < stripInitialFill && scanned < c.photos.count {
            let slice = Array(c.photos.dropFirst(scanned).prefix(stripBatchScan))
            if slice.isEmpty { break }
            let batch = await PhotoFilter.screen(slice, allowVehicles: allowVehicles,
                                                 limit: slice.count, scanLimit: slice.count)
            kept.append(contentsOf: batch)
            scanned += slice.count
        }
        kept = Array(kept.prefix(stripMaxKept))
        scannedCount[c.id] = scanned
        ScreeningStore.shared.save(c.id, allowVehicles: allowVehicles, kept: kept, scanned: scanned)
        // Share this verdict so other users skip screening this place.
        VerdictService.upload(id: c.id, allowVehicles: allowVehicles, kept: kept, scanned: scanned)

        if kept.isEmpty {
            // Whole pool was non-work imagery → drop the business rather than show
            // a blank strip (mirrors the gallery).
            contractors.removeAll { $0.id == c.id }
        } else {
            keptPhotos[c.id] = kept
            // Reveal once, ordered so query-matching photos (e.g. the kitchen) lead.
            screenedByID[c.id] = PhotoFilter.order(kept, query: orderQuery)
            // Then sharpen the order with rich vision tags in the background.
            enrichInBackground(c.id, kept: kept, scanned: scanned, allowVehicles: allowVehicles)
        }
    }

    /// Enrich a place shown from a cached/shared verdict that hadn't been
    /// rich-tagged yet. `needsEnrich.remove` both checks membership and consumes
    /// it, so each place enriches at most once per session even if its row
    /// re-reveals. Freshly-screened rows already enrich via `screenIfNeeded`.
    @MainActor
    private func enrichIfNeeded(_ c: Contractor) async {
        guard needsEnrich.remove(c.id) != nil,
              let kept = keptPhotos[c.id], !kept.isEmpty else { return }
        let allowVehicles = isAutoService(category: category, searchQuery: effectiveSearchQuery)
        enrichInBackground(c.id, kept: kept, scanned: scannedCount[c.id] ?? kept.count,
                           allowVehicles: allowVehicles)
    }

    /// Ask the vision model for rich, query-independent tags for a business's
    /// screened photos, then re-order the strip and re-share the enriched verdict.
    /// On-device labels are only generic scene tokens (no "bumper", no car make),
    /// so without this, query ranking can't work for auto or specific home
    /// searches. Runs detached so the strip shows immediately on the on-device
    /// ordering; this only refines it a beat later (and once per place, shared).
    private func enrichInBackground(_ id: String, kept: [ScreenedPhoto],
                                    scanned: Int, allowVehicles: Bool) {
        Task { @MainActor in
            // nil = the tagger didn't run (off / network / error) → leave the
            // verdict un-enriched so a later visit retries it.
            guard let enriched = await PhotoTagService.enrich(kept, allowVehicles: allowVehicles) else { return }
            // The row may have been dropped, or the Auto⇄Moto filter switched
            // (which clears state), while tagging was in flight.
            guard contractors.contains(where: { $0.id == id }) else { return }
            // Re-order/re-share only when the tags actually changed the labels;
            // either way mark the verdict enriched so we don't re-tag every visit.
            if enriched != kept {
                keptPhotos[id] = enriched
                screenedByID[id] = PhotoFilter.order(enriched, query: orderQuery)
            }
            ScreeningStore.shared.save(id, allowVehicles: allowVehicles, kept: enriched,
                                       scanned: scanned, enriched: true)
            VerdictService.upload(id: id, allowVehicles: allowVehicles, kept: enriched,
                                  scanned: scanned, enriched: true)
        }
    }
}

/// How many of the best-matching businesses the list shows before "See more".
private let initialVisibleCount = 5

/// Screening budget per row: scan `stripBatchScan` source photos at a time,
/// deeper into the pool only if early shots are rejected, keeping up to
/// `stripMaxKept` (a few spares beyond the three the mosaic shows, so the
/// query-first ordering has room to pick the best three — and the gallery
/// inherits them pre-screened).
private let stripBatchScan = 4
private let stripMaxKept = 10
/// Target number of work photos for the initial fill — a little over the three
/// the mosaic displays, so a rejected early shot doesn't leave a gap.
private let stripInitialFill = 4

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractorListRow
// One contractor (Figma 793:1779): a name + "Get quote" header row, a rating
// row, then a fixed 234pt photo mosaic — one large left tile and two stacked
// right tiles — showing up to 3 of the business's work photos, ordered so the
// ones most related to the user's request lead. The price estimate lives in the
// screen header (one per job), not per business. Tapping a photo (or the name)
// opens the gallery for this contractor.
// ─────────────────────────────────────────────────────────────────────────────

private struct ContractorListRow: View {
    let contractor: Contractor
    /// Screened work photos, or nil while screening is still in flight (the mosaic
    /// then shows gray placeholders so the row's text isn't held back).
    let photos: [String]?
    /// True only when an ACTIVE contractor licence was found for this business.
    /// False means "no licence on file" — which includes every business outside
    /// California — so it must never be rendered as "Unlicensed".
    let isLicensed: Bool
    /// Opens the gallery on this contractor at the given photo index (0 for the
    /// name tap; the mosaic passes the exact tile tapped).
    let onOpen: (Int) -> Void
    let onReviews: () -> Void
    /// Fired by the row's "Get quote" capsule — requests a quote from this business.
    let onQuote: () -> Void

    // Exact Figma values (793:1779).
    private let sideInset: CGFloat = 16      // content left/right margin
    private let mosaicHeight: CGFloat = 234  // fixed height of the photo block
    private let mosaicGap: CGFloat = 8       // gap between tiles (both axes)
    private let tileRadius: CGFloat = 16     // per-tile corner radius
    /// Up to this many of the (query-ordered) work photos appear in the mosaic —
    /// the three most related to the user's request.
    private let maxTiles = 3

    var body: some View {
        // Header block (8pt above the photo mosaic).
        VStack(alignment: .leading, spacing: 8) {
            // ── Name + quote CTA / rating ─────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Button(action: { onOpen(0) }) {
                        Text(contractor.name)
                            .font(.h3)                      // Lato 700 / 18
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Secondary capsule, 32pt tall (Figma "Button Secondary").
                    Button(action: onQuote) {
                        Text("Get quote")
                            .font(.h4)                      // Lato 700 / 14
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .secondaryButtonBackground()
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 32)

                HStack(spacing: 8) {
                    // Stars + rating number are display-only; only "31 reviews"
                    // is the tappable link to the Google reviews.
                    ListStarRow(rating: contractor.rating)
                    HStack(spacing: 0) {
                        if contractor.reviewCount > 0 {
                            Text("\(contractor.rating, specifier: "%.1f") • ")
                            Button(action: onReviews) {
                                Text("\(contractor.reviewCount) reviews")
                                    .underline()
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        // Only ever shown against a verified ACTIVE state licence;
                        // its absence says nothing, so nothing is drawn.
                        if isLicensed {
                            Text(contractor.reviewCount > 0 ? " • Licensed" : "Licensed")
                        }
                    }
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, sideInset)

            // ── Photo mosaic — up to 3 query-relevant work photos ─────────────
            // Figma 793:1779: a fixed 234pt-tall block — one large left photo and
            // two stacked right photos (8pt gaps, r16). `photos` arrives already
            // ordered query-first (PhotoFilter.order), so the first three are the
            // shots most related to the user's request. The layout adapts when
            // fewer than three exist (1 → single tile, 2 → left + one right) so no
            // empty tile is ever shown; nil means still screening → placeholders.
            mosaic
                .frame(height: mosaicHeight)
                .padding(.horizontal, sideInset)
        }
    }

    // ── Mosaic layouts ────────────────────────────────────────────────────────
    // Tiles are given DEFINITE sizes (via GeometryReader) rather than flexible
    // frames: `.scaledToFill()` only clips correctly against a concrete frame —
    // with a flexible one the image renders at its natural size and overflows.
    private var mosaic: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - mosaicGap) / 2   // 181 at the 402pt width
            let rowH = (mosaicHeight - mosaicGap) / 2      // 113
            Group {
                if let photos {
                    let shots = Array(photos.prefix(maxTiles))
                    switch shots.count {
                    case 0:
                        // Defensive: an empty screened set means the row is being
                        // dropped; show placeholders rather than a blank block.
                        placeholderMosaic(colW: colW, rowH: rowH)
                    case 1:
                        // Single full-width tile.
                        photoTile(shots[0], index: 0, width: geo.size.width, height: mosaicHeight)
                    case 2:
                        // Two equal full-height tiles.
                        HStack(spacing: mosaicGap) {
                            photoTile(shots[0], index: 0, width: colW, height: mosaicHeight)
                            photoTile(shots[1], index: 1, width: colW, height: mosaicHeight)
                        }
                    default:
                        // Large left + two stacked right.
                        HStack(spacing: mosaicGap) {
                            photoTile(shots[0], index: 0, width: colW, height: mosaicHeight)
                            VStack(spacing: mosaicGap) {
                                photoTile(shots[1], index: 1, width: colW, height: rowH)
                                photoTile(shots[2], index: 2, width: colW, height: rowH)
                            }
                        }
                    }
                } else {
                    placeholderMosaic(colW: colW, rowH: rowH)
                }
            }
        }
    }

    // The full 1-big-left + 2-stacked-right skeleton, shown while screening.
    private func placeholderMosaic(colW: CGFloat, rowH: CGFloat) -> some View {
        HStack(spacing: mosaicGap) {
            placeholderTile(width: colW, height: mosaicHeight)
            VStack(spacing: mosaicGap) {
                placeholderTile(width: colW, height: rowH)
                placeholderTile(width: colW, height: rowH)
            }
        }
    }

    // One work-photo tile at a concrete size: fill, clip to r16, tappable.
    private func photoTile(_ s: String, index: Int, width: CGFloat, height: CGFloat) -> some View {
        Button(action: { onOpen(index) }) {
            // Same URL the screener already downloaded, so this is a cache hit —
            // no extra Places Photo request.
            PlacesImage(url: URL(string: PlacesService.photoURL(s, width: PlacesService.listPhotoWidth))) { placeholderFill }
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: tileRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // A gray placeholder tile at a concrete size (20% white), shown until a photo
    // resolves.
    private func placeholderTile(width: CGFloat, height: CGFloat) -> some View {
        placeholderFill
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: tileRadius, style: .continuous))
    }

    // Gray placeholder fill (20% white) shown until a photo resolves.
    private var placeholderFill: some View { Color.white.opacity(0.2) }
}

/// $-figure for the header estimate: "800", "2k", "1.5k" (Figma shows the
/// half-thousand, so keep one decimal instead of flooring 1500 to "1k").
private func money(_ v: Int) -> String {
    guard v >= 1000 else { return "\(v)" }
    let hundreds = (v % 1000) / 100
    return hundreds == 0 ? "\(v / 1000)k" : "\(v / 1000).\(hundreds)k"
}

private struct ListStarRow: View {
    let rating: Double
    /// Whole stars only, floored — Figma 765:13844 draws 4 filled for a 4.7, so a
    /// partial star never rounds up to a full one.
    private var filled: Int { min(max(Int(rating), 0), 5) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5) { i in
                Image(systemName: i < filled ? "star.fill" : "star")
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(i < filled ? AppColors.starFilled : AppColors.starEmpty)
            }
        }
    }
}
