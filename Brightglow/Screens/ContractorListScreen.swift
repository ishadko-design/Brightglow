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
    /// (drives the strip's "load more as you scroll" batching).
    @State private var scannedCount: [String: Int] = [:]
    /// Captured from the live fetch so the gallery can keep paginating this search.
    @State private var nextPageToken: String? = nil
    @State private var resolvedCoord: CLLocationCoordinate2D? = nil
    @State private var isLoading   = false
    @State private var estimate: PriceTier? = nil

    @State private var sentToAll = false
    @State private var goGallery = false
    @State private var startContractorID: String? = nil
    /// The contractor the gallery is currently showing — used to scroll the list
    /// back to that exact spot when the user returns (they may have skipped past
    /// the one they opened).
    @State private var lastViewedID: String? = nil
    /// Auto & moto only: which vehicle type to show (defaults to cars).
    @State private var vehicle: VehicleFilter = .auto

    private var headerTitle: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
    }

    /// The Auto & moto category being viewed, if any (drives the vehicle filter).
    private var autoCategory: AutoCategory? { autoCategoryItems.first { $0.name == category } }

    /// Query actually sent to Places — the moto variant when the filter is on Moto.
    private var effectiveSearchQuery: String {
        autoCategory?.query(for: vehicle) ?? searchQuery
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top

            ZStack(alignment: .top) {
                AppColors.bg.ignoresSafeArea()

                if isLoading && contractors.isEmpty {
                    statusView(spinner: true, text: "Finding contractors near you…")
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
                presetEstimate: estimate,
                initialPageToken: nextPageToken,
                lastViewedID: $lastViewedID
            )
        }
    }

    // ── Scrollable list of contractor rows ────────────────────────────────────
    // Figma 444:1275 — blocks stacked with a 24pt gap.
    private func list(bottomInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 24) {
                    ForEach(contractors) { contractor in
                        ContractorListRow(
                            contractor: contractor,
                            // nil = not screened yet → row shows gray placeholders.
                            photos: screenedByID[contractor.id],
                            priceTier: estimate ?? contractor.priceTiers.first,
                            onOpen: { open(contractor) },
                            onReviews: { openReviews(for: contractor) },
                            onNearEnd: { Task { await screenMore(contractor) } }
                        )
                        .id(contractor.id)
                        // Lazy: screen this contractor's photos only when its row
                        // scrolls into view (LazyVStack renders rows on demand).
                        .task { await screenIfNeeded(contractor) }
                    }
                }
                // Clears the header bar (~64pt) + a 12pt gap. The ScrollView
                // already starts below the safe area, so topInset is NOT added
                // here (doing so double-counts it and leaves a large gap).
                .padding(.top, 64 + 12)
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
        HStack(alignment: .center, spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                Text(headerTitle)
                    .font(.h2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !contractors.isEmpty {
                    Text("\(contractors.count) businesses")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            // Absorbs the slack so the right-hand controls stay pinned right.
            .frame(maxWidth: .infinity, alignment: .leading)

            // Auto ⇄ Moto filter — only for Auto & moto categories.
            if autoCategory != nil { vehicleFilter }

            if !contractors.isEmpty {
                Button(action: sendToAll) {
                    Text(sentToAll ? "Sent ✓" : "Send to all")
                        .font(.h4)
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(height: 29)
                        .secondaryButtonBackground()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 16)
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
    private func sendToAll() {
        guard !sentToAll else { return }
        withAnimation(.easeInOut(duration: 0.2)) { sentToAll = true }
    }

    private func open(_ contractor: Contractor) {
        startContractorID = contractor.id
        goGallery = true
    }

    private func openReviews(for contractor: Contractor) {
        if let url = URL(string: "https://search.google.com/local/reviews?placeid=\(contractor.id)") {
            openURL(url)
        }
    }

    // ── Data loading + progressive photo screening ────────────────────────────
    @MainActor
    private func load() async {
        guard contractors.isEmpty else { return }
        isLoading = true

        let resolved = await ContractorLoader.resolveCoordinate(
            preset: presetCoordinate, location: location)

        let query = effectiveSearchQuery
        if let coord = resolved {
            let page = await ContractorLoader.fetchLivePage(
                category: category, searchQuery: query, near: coord)
            contractors = page.contractors
            nextPageToken = page.nextPageToken
            resolvedCoord = coord
            // Reuse verdicts from a previous launch so businesses screened before
            // show their photos immediately without re-downloading the pool.
            let allowVehicles = isAutoService(category: category, searchQuery: query)
            for c in contractors {
                guard let v = ScreeningStore.shared.get(c.id, allowVehicles: allowVehicles) else { continue }
                if !v.kept.isEmpty {
                    // Cached work photos → show them immediately.
                    screenedByID[c.id] = v.kept
                    scannedCount[c.id] = v.scanned
                } else if v.scanned >= c.photos.count {
                    // Whole pool scanned, no work photos → mark scanned (skip
                    // re-screening); dropped just below. A *partial* empty verdict
                    // is left unprimed so the row re-scans deeper this time.
                    scannedCount[c.id] = v.scanned
                }
            }
            // Drop businesses confirmed to have no work photos in their whole pool,
            // so they don't reappear as blank rows on a later visit.
            contractors.removeAll { c in
                (scannedCount[c.id] ?? 0) >= c.photos.count && (screenedByID[c.id]?.isEmpty ?? true)
            }
            if !contractors.isEmpty {
                let hints = EstimateService.priceMentions(in: contractors.flatMap(\.reviews))
                Task { @MainActor in
                    estimate = await ContractorLoader.estimate(
                        category: category, searchQuery: query, near: coord,
                        priceHints: hints)
                }
            }
        } else {
            contractors = ContractorLoader.fallback(
                category: category, searchQuery: query)
        }
        isLoading = false
        // Photos are screened lazily per row (see `screenIfNeeded`) so we only pay
        // for the businesses the user actually scrolls to.
    }

    /// Re-run the search from scratch (used when the Auto ⇄ Moto filter changes).
    private func reload() async {
        contractors = []
        screenedByID = [:]
        scannedCount = [:]
        nextPageToken = nil
        estimate = nil
        sentToAll = false
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
        var kept: [String] = []
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

        if kept.isEmpty {
            // Whole pool was non-work imagery → drop the business rather than show
            // a blank strip (mirrors the gallery).
            contractors.removeAll { $0.id == c.id }
        } else {
            screenedByID[c.id] = kept   // reveal once, replacing the placeholders
        }
    }

    /// Reveal more strip photos as the user scrolls the strip toward its end —
    /// up to `stripMaxKept`, a batch at a time, so we only fetch what's viewed.
    @MainActor
    private func screenMore(_ c: Contractor) async {
        guard (scannedCount[c.id] ?? 0) < c.photos.count,
              (screenedByID[c.id]?.count ?? 0) < stripMaxKept else { return }
        await screenBatch(c)
    }

    /// Screen the next window of a contractor's source photos and append keepers.
    @MainActor
    private func screenBatch(_ c: Contractor) async {
        guard !screening.contains(c.id) else { return }
        screening.insert(c.id)
        defer { screening.remove(c.id) }
        let start = scannedCount[c.id] ?? 0
        let slice = Array(c.photos.dropFirst(start).prefix(stripBatchScan))
        guard !slice.isEmpty else { scannedCount[c.id] = start; return }
        let allowVehicles = isAutoService(category: category, searchQuery: effectiveSearchQuery)
        let kept = await PhotoFilter.screen(slice, allowVehicles: allowVehicles,
                                            limit: slice.count, scanLimit: slice.count)
        var current = screenedByID[c.id] ?? []
        current.append(contentsOf: kept)
        screenedByID[c.id] = Array(current.prefix(stripMaxKept))   // [] until a keeper lands
        scannedCount[c.id] = start + slice.count
        // Persist so a later launch reuses this verdict instead of re-screening.
        ScreeningStore.shared.save(c.id, allowVehicles: allowVehicles,
                                   kept: screenedByID[c.id] ?? [], scanned: scannedCount[c.id] ?? 0)
    }
}

/// Strip budget: the first batch screens `stripBatchScan` source photos (so a row
/// the user never scrolls costs only ~4 photo fetches), then each scroll of the
/// strip toward its end screens the next batch, growing up to `stripMaxKept`.
private let stripBatchScan = 4
private let stripMaxKept = 10
/// Target number of work photos for the initial strip fill (scan deeper if early
/// photos are rejected, so a row isn't left blank).
private let stripInitialFill = 4

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractorListRow
// One contractor (Figma 444:1275): a logo + name / price / rating header, then a
// horizontal strip of 112×136 work photos below. Tapping a photo (or the name)
// opens the gallery for this contractor.
// ─────────────────────────────────────────────────────────────────────────────

private struct ContractorListRow: View {
    let contractor: Contractor
    /// Screened work photos, or nil while screening is still in flight (the strip
    /// then shows gray placeholders so the row's text isn't held back).
    let photos: [String]?
    let priceTier: PriceTier?
    let onOpen: () -> Void
    let onReviews: () -> Void
    /// Fired when the last loaded strip photo appears — cue to load the next batch.
    var onNearEnd: () -> Void = {}

    // Exact Figma values.
    private let sideInset: CGFloat = 24      // content left/right margin
    private let imageSize = CGSize(width: 112, height: 136)

    var body: some View {
        // Header block (8pt above the photo strip).
        VStack(alignment: .leading, spacing: 8) {
            // ── Logo + name / price / rating ──────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    logo
                    Button(action: onOpen) {
                        Text(contractor.name)
                            .font(.h3)                      // Lato 700 / 18
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if let tier = priceTier {
                    Text("Est prices: $\(money(tier.min))–\(money(tier.max))")
                        .font(.bodySmall)                   // Poppins 300 / 14
                        .foregroundStyle(.white)
                }

                HStack(spacing: 8) {
                    // Stars + rating number are display-only; only the word
                    // "reviews" is the tappable link to the Google reviews.
                    ListStarRow(rating: contractor.rating)
                    if contractor.reviewCount > 0 {
                        Text("\(contractor.rating, specifier: "%.1f") • \(contractor.reviewCount)")
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.5))
                        Button(action: onReviews) {
                            Text("reviews")
                                .font(.bodySmall)
                                .foregroundStyle(.white.opacity(0.5))
                                .underline()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, sideInset)

            // ── Horizontal photo strip — 112×136, r16, 8pt gap ────────────────
            // Plain HStack (not LazyHStack): a LazyHStack fails to re-realize its
            // tiles when `photos` flips from nil (placeholders) to the screened set,
            // so the photos never appear until the screen is rebuilt. The HStack
            // renders only what's been screened so far; we screen the next batch
            // when the user scrolls the strip near its end (see onScrollGeometry
            // change below), which is the lazy-load trigger — not eager onAppear.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let photos {
                        ForEach(Array(photos.enumerated()), id: \.offset) { _, s in
                            Button(action: onOpen) {
                                // Small rendition — same URL the screener already
                                // downloaded, so the thumbnail is a cache hit (no
                                // extra Places Photo request).
                                tile { PlacesImage(url: URL(string: PlacesService.photoURL(s, width: PlacesService.listPhotoWidth))) { placeholderFill }
                                        .scaledToFill() }
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        // Not screened yet — gray placeholders while photos load.
                        ForEach(0..<placeholderCount, id: \.self) { _ in
                            tile { placeholderFill }
                        }
                    }
                }
                .padding(.horizontal, sideInset)
                .frame(height: imageSize.height)
            }
            .frame(height: imageSize.height)
            // Lazy-load more photos only when the strip is actually scrollable and
            // the user scrolls it within ~120pt of the end. Reliable horizontal
            // pagination without LazyHStack's realization bug.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.width > geo.containerSize.width &&
                geo.contentOffset.x + geo.containerSize.width >= geo.contentSize.width - 120
            } action: { wasNearEnd, isNearEnd in
                if isNearEnd && !wasNearEnd { onNearEnd() }
            }
        }
    }

    // A single 112×136 r16 strip cell.
    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: imageSize.width, height: imageSize.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // Gray placeholder fill (20% white) shown until a photo resolves.
    private var placeholderFill: some View { Color.white.opacity(0.2) }

    // How many placeholder tiles to show while screening — roughly the eventual
    // count, clamped so the strip looks populated.
    private var placeholderCount: Int { min(max(contractor.photos.count, 3), 6) }

    // 32×32 rounded-8 logo. Contractors carry no logo asset, so this is an
    // initials placeholder in the same footprint as the Figma "Profile Photo".
    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
            Text(String(contractor.name.prefix(1)))
                .font(.h4)
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
    }

    private func money(_ v: Int) -> String { v >= 1000 ? "\(v / 1000)k" : "\(v)" }
}

private struct ListStarRow: View {
    let rating: Double
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5) { i in
                Image(systemName: i < Int(rating.rounded()) ? "star.fill" : "star")
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(i < Int(rating.rounded()) ? AppColors.starFilled : AppColors.starEmpty)
            }
        }
    }
}
