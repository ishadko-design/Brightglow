import SwiftUI
import CoreLocation

/// Tracks the sheet ScrollView's top offset so the BottomSheet knows when the
/// content is scrolled to the top (and an over-pull can collapse it).
private struct SheetScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractorGalleryScreen
//
// New layout (Figma node 364-800 "Open category - contractor"):
//   • One contractor at a time — no card stack, no swipe. Navigation between
//     contractors is via the pinned Skip / Request quote buttons only, which are
//     the same size.
//   • A full-width photo that is NOT full-screen: it ends ~40pt behind the bottom
//     sheet's lowest (collapsed) position so it never peeks past the rounded
//     corners.
//   • A horizontal "gallery image viewer" strip of every photo in the stack sits
//     just above the sheet, replacing the old pagination dots.
//   • The bottom sheet reuses the shared `BottomSheet` component, so its rounded
//     corners and drag / over-pull-to-collapse behavior are identical to the
//     main screen.
//   • The top bar matches the main screen's header treatment.
// ─────────────────────────────────────────────────────────────────────────────

struct ContractorGalleryScreen: View {
    var category: String = ""
    var searchQuery: String = ""
    var aiResult: AIResult? = nil
    /// When set (manual ZIP/city or an already-resolved fix), used instead of GPS.
    var presetCoordinate: CLLocationCoordinate2D? = nil

    /// When the gallery is opened from the List view, the already-loaded
    /// contractors and their screened work photos are handed over so we don't
    /// re-fetch or re-screen. `startContractorID` is the contractor whose photo
    /// was tapped — it's surfaced first. `presetEstimate` keeps the price line in
    /// step with the list.
    var preloadedContractors: [Contractor]? = nil
    var preScreened: [String: [String]] = [:]
    var startContractorID: String? = nil
    var presetEstimate: PriceTier? = nil
    /// Next-page token from the List view's fetch, so the gallery can keep
    /// loading more contractors as the user swipes through the stack.
    var initialPageToken: String? = nil
    /// Reports the contractor currently on top, so the List view can restore to
    /// the spot the user navigated to (they may have skipped past the one they
    /// opened) when they go back.
    var lastViewedID: Binding<String?>? = nil

    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var location = LocationProvider()
    @State private var contractors: [Contractor] = []
    @State private var isLoading   = false
    @State private var showQuote   = false
    @State private var selectedContractor: Contractor? = nil
    @State private var estimate: PriceTier? = nil
    @State private var totalCount  = 0

    @State private var sheetDetent: SheetDetent = .collapsed
    @State private var sheetScrolledToTop = true
    /// Screened work-photo URLs per contractor id. nil = not yet screened
    /// (show loading); [] = no work photos (show placeholder). Populated ahead of
    /// time so a newly-surfaced contractor doesn't stall on the screen.
    @State private var screenedByID: [String: [String]] = [:]
    /// Pagination — keep loading more contractors as the stack runs low.
    @State private var nextPageToken: String? = nil
    @State private var pagingCoord: CLLocationCoordinate2D? = nil
    @State private var isLoadingMore = false

    private var topContractor: Contractor? { contractors.last }

    private var headerTitle: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset    = proxy.safeAreaInsets.top
            let bottomInset = proxy.safeAreaInsets.bottom
            let fullHeight  = topInset + proxy.size.height + bottomInset

            // Collapsed sheet height (lowest position). The photo ends 40pt behind
            // this line so it tucks under the rounded corners. Tuned so the first
            // line of the first review peeks above the pinned buttons.
            let collapsedSheetH = fullHeight * 0.305
            let imageHeight     = fullHeight - collapsedSheetH + 40
            // Leave the header visible when the sheet is fully expanded (same as
            // the main screen: ~60pt header + 16pt gap).
            let headerInset: CGFloat = topInset + 16

            ZStack(alignment: .bottom) {
                AppColors.bg.ignoresSafeArea()

                if isLoading && contractors.isEmpty {
                    statusView(spinner: true, text: "Finding businesses near you")
                } else if contractors.isEmpty && totalCount == 0 {
                    // Resolved a location but the area returned no contractors.
                    notFoundView
                } else if contractors.isEmpty {
                    statusView(spinner: false, text: "No more contractors")
                } else if let contractor = topContractor {

                    // ── Photo + thumbnail strip (resets per contractor) ───────
                    GalleryPhotoView(
                        photos: screenedByID[contractor.id],
                        width: proxy.size.width,
                        imageHeight: imageHeight,
                        stripBottomPadding: collapsedSheetH + 12
                    )
                    .id(contractor.id)
                    .ignoresSafeArea()

                    // ── Bottom sheet (shared component) ───────────────────────
                    BottomSheet(
                        detent: $sheetDetent,
                        contentIsAtTop: sheetScrolledToTop,
                        collapsedHeight: collapsedSheetH,
                        midHeight: collapsedSheetH,
                        fullTopInset: headerInset
                    ) {
                        sheetBody(for: contractor, bottomInset: bottomInset)
                    }

                    // ── Pinned Skip / Request quote — equal sizes ─────────────
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ctaFooter(width: proxy.size.width, bottomInset: bottomInset)
                    }
                    .zIndex(50)
                    // The bar is always pinned at the bottom at a fixed width, so
                    // it must never inherit the skip/quote spring or the sheet's
                    // drag animation — otherwise it slides around horizontally.
                    .transaction { $0.animation = nil }
                }

                // ── Header — matches the main screen's top bar ────────────────
                GalleryHeader(
                    title: topContractor?.name ?? headerTitle,
                    subtitle: priceText(for: topContractor),
                    onBack: { dismiss() }
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .zIndex(100)
            }
            // The shared BottomSheet expects to own the bottom safe area (same as
            // MainScreen); without this the sheet sits short and the footer lifts.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .task {
            await loadContractors()
            totalCount = contractors.count
        }
        // Screen the current contractor + the next couple ahead of time, so the
        // photo is ready the instant a contractor is surfaced (no load stall).
        .task(id: topContractor?.id) { await prefetchUpcoming() }
        // Keep the List view's restore target in step with the contractor on top.
        .onChange(of: topContractor?.id, initial: true) { _, id in
            if let id { lastViewedID?.wrappedValue = id }
        }
        .navigationDestination(isPresented: $showQuote) {
            QuoteRequestScreen(contractor: selectedContractor, requestSummary: headerTitle)
        }
    }

    // ── Sheet content — reviews only (handle is supplied by BottomSheet) ───────
    private func sheetBody(for contractor: Contractor, bottomInset: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                reviewsHeader(for: contractor)
                if contractor.reviews.isEmpty {
                    Text("No reviews yet")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 4)
                } else {
                    ForEach(Array(contractor.reviews.prefix(5))) { ReviewRowGallery(review: $0) }
                }
                // Clear the pinned CTAs at the bottom.
                Color.clear.frame(height: 48 + 32 + bottomInset)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .background(GeometryReader { g in
                Color.clear.preference(
                    key: SheetScrollKey.self,
                    value: g.frame(in: .named("sheetScroll")).minY)
            })
        }
        .coordinateSpace(name: "sheetScroll")
        .scrollDisabled(sheetDetent != .full)
        .onPreferenceChange(SheetScrollKey.self) { minY in
            sheetScrolledToTop = minY > -2
        }
    }

    // "Reviews" section title (enlarged) with the rating summary on the right —
    // the summary opens the contractor's Google reviews.
    private func reviewsHeader(for contractor: Contractor) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Reviews")
                .font(.h2)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            if contractor.reviewCount > 0 {
                // Stars + rating number are display-only; only "reviews" is the
                // link (with a ≥44pt-tall tap box to avoid accidental taps).
                HStack(spacing: 8) {
                    StarRow(rating: contractor.rating)
                    Text("\(contractor.rating, specifier: "%.1f") • \(contractor.reviewCount)")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.5))
                    Button {
                        if let url = googleReviewsURL(for: contractor) { openURL(url) }
                    } label: {
                        Text("reviews")
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.5))
                            .underline()
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // Price line shown under the contractor name in the header.
    private func priceText(for contractor: Contractor?) -> String? {
        guard let contractor, let tier = estimate ?? contractor.priceTiers.first else { return nil }
        return "Est prices: $\(money(tier.min))–\(money(tier.max))"
    }

    private func money(_ v: Int) -> String { v >= 1000 ? "\(v / 1000)k" : "\(v)" }

    /// Deep link to the contractor's Google reviews. `id` is the Google place id
    /// on the live path (mock contractors won't resolve, which is fine here).
    private func googleReviewsURL(for contractor: Contractor) -> URL? {
        URL(string: "https://search.google.com/local/reviews?placeid=\(contractor.id)")
    }

    // Pinned Skip / Request quote — equal-width buttons on a fading floor
    // (Figma "CTAs": two 48pt-tall buttons, radius 32, 8pt gap).
    private func ctaFooter(width: CGFloat, bottomInset: CGFloat) -> some View {
        // Exact equal widths from the known screen width — no reliance on the
        // parent's width proposal (which has overflowed past the screen edges).
        let buttonWidth = max(0, (width - 32 - 8) / 2)
        return HStack(spacing: 8) {
            Button(action: skipTop) {
                Text("Next")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth, height: 48)
                    .background {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial)
                            AppColors.btnSecondary
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: quoteTop) {
                Text("Request quote")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: buttonWidth, height: 48)
                    .background(AppColors.btnPrimary, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
        .padding(.bottom, 16 + bottomInset)
        .frame(width: width)
        // Opaque floor (matches the sheet color) that fades in at the top, so the
        // reviews behind never show through around the buttons.
        .background(
            LinearGradient(
                stops: [
                    .init(color: AppColors.bg.opacity(0), location: 0.0),
                    .init(color: AppColors.bg,            location: 0.45),
                    .init(color: AppColors.bg,            location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    private func statusView(spinner: Bool, text: String) -> some View {
        VStack(spacing: 16) {
            if spinner {
                ProgressView().tint(.white).scaleEffect(1.4)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 60))
                    .foregroundStyle(AppColors.textSecondary)
            }
            Text(text)
                .font(.h3)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxHeight: .infinity)
    }

    // Empty state when a location resolved but no contractors were found there.
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
        .frame(maxHeight: .infinity)
    }

    // ── Top-contractor actions ────────────────────────────────────────────────
    // Note: no `withAnimation` here. Wrapping the contractor swap in a spring
    // animated the *entire* view tree (header, sheet, footer) on every change,
    // which is what made everything jump. The sheet collapse animates on its own
    // (BottomSheet animates its detent internally); the photo swap is instant.
    private func skipTop() {
        sheetDetent = .collapsed
        if !contractors.isEmpty { contractors.removeLast() }
        loadMoreIfNeeded()
    }

    private func quoteTop() {
        selectedContractor = contractors.last
        sheetDetent = .collapsed
        if !contractors.isEmpty { contractors.removeLast() }
        showQuote = true
        loadMoreIfNeeded()
    }

    /// Fetch the next page of contractors as the stack runs low, so swiping keeps
    /// surfacing fresh results while Google still has content for this search.
    /// New results are prepended (the top card is `contractors.last`), so they're
    /// shown only after the current ones are consumed.
    private func loadMoreIfNeeded() {
        guard !isLoadingMore, contractors.count <= 4,
              let token = nextPageToken, let coord = pagingCoord else { return }
        isLoadingMore = true
        Task { @MainActor in
            let page = await ContractorLoader.fetchLivePage(
                category: category, searchQuery: searchQuery, near: coord, pageToken: token)
            let existing = Set(contractors.map(\.id))
            let fresh = page.contractors.filter { !existing.contains($0.id) }
            contractors.insert(contentsOf: fresh, at: 0)
            totalCount += fresh.count
            nextPageToken = page.nextPageToken
            isLoadingMore = false
        }
    }

    /// Puts the tapped contractor last (the gallery shows `contractors.last` as
    /// the top contractor), so opening a photo from the list lands on it.
    private func orderedForGallery(_ list: [Contractor]) -> [Contractor] {
        guard let startID = startContractorID,
              let idx = list.firstIndex(where: { $0.id == startID }) else { return list }
        var rest = list
        let selected = rest.remove(at: idx)
        return rest + [selected]
    }

    // ── Photo screening / prefetch ────────────────────────────────────────────
    // Reuses the screening the List view already did: contractors handed over from
    // the list carry their screened photos in `preScreened`, so we never download
    // their pool again to re-classify it. We only screen contractors that arrived
    // here via pagination (and so were never in the list), and we warm the first
    // photo at display resolution. Runs on contractor change, covering the current
    // contractor and the next one so a skip doesn't stall.
    @MainActor
    private func prefetchUpcoming() async {
        let upcoming = Array(contractors.suffix(2).reversed())   // current, then next
        // Auto & moto providers: keep vehicle photos (they're the work examples).
        let allowVehicles = isAutoService(category: category, searchQuery: searchQuery)
        for contractor in upcoming {
            // Already screened in this session — reused from the list hand-off or
            // an earlier surface. Just warm the first photo; no re-download.
            if let existing = screenedByID[contractor.id] {
                if let first = existing.first, let u = URL(string: first) {
                    await ImageCache.shared.prefetch(u)
                }
                continue
            }
            // Persisted verdict from a previous launch — reuse, no download.
            if let v = ScreeningStore.shared.get(contractor.id, allowVehicles: allowVehicles) {
                let ordered = PhotoFilter.order(v.kept, query: searchQuery)
                screenedByID[contractor.id] = ordered
                if ordered.isEmpty {
                    contractors.removeAll { $0.id == contractor.id }
                    if totalCount > 0 { totalCount -= 1 }
                } else if let first = ordered.first, let u = URL(string: first) {
                    await ImageCache.shared.prefetch(u)
                }
                continue
            }
            // Shared verdict from another user — reuse, no download.
            if let v = await VerdictService.fetch(ids: [contractor.id], allowVehicles: allowVehicles)[contractor.id] {
                ScreeningStore.shared.save(contractor.id, allowVehicles: allowVehicles,
                                           kept: v.kept, scanned: v.scanned)
                let ordered = PhotoFilter.order(v.kept, query: searchQuery)
                screenedByID[contractor.id] = ordered
                if ordered.isEmpty {
                    contractors.removeAll { $0.id == contractor.id }
                    if totalCount > 0 { totalCount -= 1 }
                } else if let first = ordered.first, let u = URL(string: first) {
                    await ImageCache.shared.prefetch(u)
                }
                continue
            }
            // Unscreened (never seen by any user): screen a capped slice rather than
            // the whole pool, then share the verdict so others skip it.
            let kept = await PhotoFilter.screen(contractor.photos, allowVehicles: allowVehicles,
                                                limit: galleryMaxKept, scanLimit: galleryScanLimit)
            let scanned = min(galleryScanLimit, contractor.photos.count)
            ScreeningStore.shared.save(contractor.id, allowVehicles: allowVehicles, kept: kept, scanned: scanned)
            VerdictService.upload(id: contractor.id, allowVehicles: allowVehicles, kept: kept, scanned: scanned)
            let ordered = PhotoFilter.order(kept, query: searchQuery)
            guard !ordered.isEmpty else {
                // No usable work photos → drop the business entirely rather than
                // showing an empty placeholder. Keep totalCount in step so the
                // "x/y businesses" counter stays correct.
                screenedByID[contractor.id] = []
                contractors.removeAll { $0.id == contractor.id }
                if totalCount > 0 { totalCount -= 1 }
                continue
            }
            screenedByID[contractor.id] = ordered
            // Warm only the FIRST photo at full resolution — the one shown when the
            // business surfaces. The rest load on demand as the user pages photos,
            // so we don't fetch high-res shots nobody looks at.
            if let first = ordered.first, let u = URL(string: first) {
                await ImageCache.shared.prefetch(u)
            }
        }
        // Dropping no-photo businesses can thin the stack — top up if we can.
        loadMoreIfNeeded()
    }

    // ── Data loading (mirrors SwipeScreen) ────────────────────────────────────
    @MainActor
    private func loadContractors() async {
        guard contractors.isEmpty else { return }

        // Handed over from the List view — reuse its contractors and screened
        // photos verbatim, surfacing the tapped contractor first.
        if let preloaded = preloadedContractors {
            screenedByID = preScreened
            estimate = presetEstimate
            contractors = orderedForGallery(preloaded)
            // Continue the List view's search as the user swipes past its results.
            nextPageToken = initialPageToken
            pagingCoord = presetCoordinate
            return
        }

        isLoading = true
        defer { isLoading = false }

        let resolved = await ContractorLoader.resolveCoordinate(
            preset: presetCoordinate, location: location)

        if let coord = resolved {
            // We have a real location: trust the live result for that area. If it
            // comes back empty, show an empty state — do NOT mask it with the
            // location-independent mock list (that's what made changing the city,
            // e.g. to Kyiv, appear to do nothing).
            let page = await ContractorLoader.fetchLivePage(
                category: category, searchQuery: searchQuery, near: coord)
            let live = page.contractors
            contractors = live
            nextPageToken = page.nextPageToken
            pagingCoord = coord
            if !live.isEmpty {
                let hints = EstimateService.priceMentions(in: live.flatMap(\.reviews))
                Task { @MainActor in
                    estimate = await ContractorLoader.estimate(
                        category: category, searchQuery: searchQuery, near: coord,
                        priceHints: hints)
                }
            }
            return
        }
        // Only with no resolvable location at all (denied / offline) do we show
        // the built-in demo contractors.
        contractors = ContractorLoader.fallback(category: category, searchQuery: searchQuery)
    }
}

/// Screening budget for contractors that reach the gallery via pagination (the
/// rest reuse the list's screening). Scan a capped slice of the pool and keep a
/// few work photos, instead of downloading all ~10 to classify.
private let galleryMaxKept = 6
private let galleryScanLimit = 8

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GalleryPhotoView
// Full-width photo (not full-screen) + the horizontal image-stack viewer that
// replaces the pagination dots. State is encapsulated so it resets per contractor.
// ─────────────────────────────────────────────────────────────────────────────

private struct GalleryPhotoView: View {
    /// Screened work-photo URLs, supplied by the screen (prefetched & cached).
    /// nil = still screening (loading); [] = no work photos (placeholder).
    let photos: [String]?
    /// Fixed content width (screen width). Sizing the photo with a *fixed* width
    /// rather than `maxWidth: .infinity` is essential: `scaledToFill` + a fixed
    /// height otherwise proposes a width of height×aspectRatio, which leaks into
    /// the layout and makes the whole screen (header/footer/sheet) fluctuate as
    /// the displayed image's aspect ratio changes.
    let width: CGFloat
    let imageHeight: CGFloat
    /// Distance from the bottom of the screen to the bottom of the strip — places
    /// it just above the collapsed sheet.
    let stripBottomPadding: CGFloat

    @State private var photoIndex = 0
    /// The photo tapped for full-screen zoom (nil = viewer closed).
    @State private var zoomItem: ZoomItem? = nil

    private var shownPhotos: [String] { photos ?? [] }

    var body: some View {
        let photoURL = shownPhotos.indices.contains(photoIndex)
            ? URL(string: shownPhotos[photoIndex]) : nil

        ZStack(alignment: .top) {
            // ── Full-width photo, anchored to the top ─────────────────────────
            Group {
                if photos == nil {
                    // Still screening — show a neutral loading surface, not the
                    // unfiltered pool.
                    loadingSurface
                } else if shownPhotos.isEmpty {
                    // Whole pool was non-work imagery (filtered out) — branded
                    // placeholder rather than the rejected junk.
                    placeholder
                } else {
                    PlacesImage(url: photoURL) { Color.black }
                        .scaledToFill()
                        .frame(width: width, height: imageHeight)
                        .clipped()
                        .id(photoIndex)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: photoIndex)
                        // Tap opens the full-screen zoomable viewer; swipe pages.
                        .contentShape(Rectangle())
                        .onTapGesture { if let photoURL { zoomItem = ZoomItem(url: photoURL) } }
                        .gesture(swipeGesture)
                }
            }
            .frame(width: width, height: imageHeight)
            .frame(maxHeight: .infinity, alignment: .top)

            // ── Gallery image viewer (thumbnail strip) ────────────────────────
            if shownPhotos.count > 1 {
                thumbnailStrip
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, stripBottomPadding)
            }
        }
        .fullScreenCover(item: $zoomItem) { item in
            PhotoZoomViewer(url: item.url) { zoomItem = nil }
        }
    }

    private var loadingSurface: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.08)],
                startPoint: .top, endPoint: .bottom
            )
            ProgressView().tint(.white.opacity(0.6))
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.08)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No work photos yet")
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(shownPhotos.enumerated()), id: \.offset) { i, s in
                    let active = i == photoIndex
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { photoIndex = i }
                    } label: {
                        PlacesImage(url: URL(string: s)) { Color.black }
                            .scaledToFill()
                            .frame(width: 52, height: 64)
                            .clipped()
                            .overlay(Color.black.opacity(active ? 0 : 0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            // Only the selected thumbnail gets a white outline;
                            // unselected ones are borderless.
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white, lineWidth: active ? 1 : 0)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .animation(.easeInOut(duration: 0.2), value: photoIndex)
    }

    private func page(_ dir: Int) {
        let count = shownPhotos.count
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            photoIndex = (photoIndex + dir + count) % count
        }
    }

    // Horizontal swipe pages photos; commit once on end so it doesn't fight the
    // tap zones. Vertical-dominant drags are ignored (they belong to the sheet).
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height),
                      abs(v.translation.width) > 40 else { return }
                page(v.translation.width < 0 ? 1 : -1)   // swipe left → next
            }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PhotoZoomViewer
// Full-screen, pinch-to-zoom + pan photo viewer. The header is just a close (X)
// button, per the design. Reuses the already-cached full-size photo so it opens
// instantly. Double-tap toggles zoom.
// ─────────────────────────────────────────────────────────────────────────────

/// Identifiable wrapper so the tapped photo drives a `fullScreenCover(item:)`.
private struct ZoomItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PhotoZoomViewer: View {
    let url: URL
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            PlacesImage(url: url) { Color.black }
                .scaledToFit()
                .scaleEffect(scale * pinch)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in
                            scale = min(max(scale * value, 1), maxScale)
                            if scale <= 1 {
                                withAnimation(.easeOut(duration: 0.2)) { offset = .zero; lastOffset = .zero }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }   // pan only when zoomed in
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero }
                        else { scale = 2.5 }
                    }
                }

            // Header — only the close (cross) button.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.35)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.top, 8)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GalleryHeader
// Matches the main screen's top bar: horizontal 16 / vertical 8 padding over the
// shared BlurredHeaderBackground.
// ─────────────────────────────────────────────────────────────────────────────

private struct GalleryHeader: View {
    let title: String
    let subtitle: String?
    let onBack: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.h2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.bodySmall)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            // Absorbs the slack and truncates so a long name never overflows.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 4pt before the 44×44 back button; content keeps 16pt off the right edge.
        .padding(.leading, 4)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(alignment: .top) { BlurredHeaderBackground() }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Small components
// ─────────────────────────────────────────────────────────────────────────────

private struct StarRow: View {
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

private struct ReviewRowGallery: View {
    let review: Review
    @State private var showingOriginal = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let s = review.authorPhotoURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase { img.resizable().scaledToFill() }
                        else { initialsCircle }
                    }
                } else { initialsCircle }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                Text(review.author)
                    .font(.h4)
                    .foregroundStyle(Color(hex: "#ECEBED"))
                StarRow(rating: Double(review.rating))
                Text(showingOriginal ? (review.originalText ?? review.text) : review.text)
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                // Only when the review was translated from another language.
                if let original = review.originalText, !original.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showingOriginal.toggle() }
                    } label: {
                        Text(showingOriginal
                             ? "See translation"
                             : "See original (\(review.originalLanguageName ?? "original"))")
                            .font(.bodySmall)
                            .underline()
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var initialsCircle: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.15))
            Text(String(review.author.prefix(1)))
                .font(.bodySmall)
                .foregroundStyle(.white)
        }
    }
}
