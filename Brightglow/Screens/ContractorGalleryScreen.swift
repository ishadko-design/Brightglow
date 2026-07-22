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
//   • One contractor at a time — no card stack, no swipe. The pinned footer is
//     Call / Request quote (equal sizes); browsing between businesses happens
//     back in the list view.
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
    /// was tapped — it's surfaced first, opened on `startPhotoIndex` (the exact
    /// photo tapped in the list strip).
    var preloadedContractors: [Contractor]? = nil
    var preScreened: [String: [String]] = [:]
    var startContractorID: String? = nil
    var startPhotoIndex: Int = 0
    /// Next-page token from the List view's fetch, so the gallery can keep
    /// loading more contractors as the user swipes through the stack.
    var initialPageToken: String? = nil
    /// Reports the contractor currently on top, so the List view can restore to
    /// the spot the user navigated to (they may have skipped past the one they
    /// opened) when they go back.
    var lastViewedID: Binding<String?>? = nil
    /// Photos the user attached before arriving here — carried to the
    /// quote-request screen.
    var attachedImages: [UIImage] = []
    /// When opened from the list's "N reviews" link, the sheet starts expanded so
    /// the reviews are visible immediately (instead of the default collapsed peek).
    var startReviewsExpanded: Bool = false
    /// The chat's `photo_terms` (a matching work-photo descriptor), carried from
    /// the list so review ordering here matches the list's — the review quoted on
    /// the list card must lead the reviews sheet, not a different one.
    var photoMatchTerms: String = ""
    /// Identity of the review the list card quoted, when the user arrived by
    /// tapping that quote. Pinned to the top of the reviews sheet so the comment
    /// they tapped is the first one they see — the card shows a single sentence
    /// lifted from mid-review, so without this the source review reads as a
    /// different comment entirely and the quote appears to have vanished.
    var pinnedReviewID: String? = nil
    /// The landing clarifying Q&A, carried through to the quote-request screen so
    /// the message a business receives includes the AI-clarified details.
    var clarifyTranscript: ClarifyTranscript = .empty

    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var location = LocationProvider()
    @State private var contractors: [Contractor] = []
    @State private var isLoading   = false
    @State private var showQuote   = false
    @State private var selectedContractor: Contractor? = nil
    @State private var totalCount  = 0

    @State private var sheetDetent: SheetDetent = .collapsed
    @State private var sheetScrolledToTop = true
    /// The "mention Brightglow" reminder shown before dialing the business.
    @State private var showCallReminder = false
    /// Screened work-photo URLs per contractor id. nil = not yet screened
    /// (show loading); [] = no work photos (show placeholder). Populated ahead of
    /// time so a newly-surfaced contractor doesn't stall on the screen.
    @State private var screenedByID: [String: [String]] = [:]
    /// Pagination — keep loading more contractors as the stack runs low.
    @State private var nextPageToken: String? = nil
    @State private var pagingCoord: CLLocationCoordinate2D? = nil
    @State private var isLoadingMore = false
    /// Businesses whose own-website photos have already been fetched this session,
    /// so a re-surface doesn't call the enrichment function again.
    @State private var websiteFetched: Set<String> = []

    private var topContractor: Contractor? { contractors.last }

    /// place_ids already counted this session. Swiping back and forth through the
    /// stack shouldn't inflate a business's view count — one look is one view.
    @State private var recordedViews: Set<String> = []

    /// Fire-and-forget so the swipe never waits on the network. `contractor.id` is
    /// the Places place_id (same key the lead carries — see QuoteRequestScreen).
    private func recordView(placeId: String) {
        guard !recordedViews.contains(placeId) else { return }
        recordedViews.insert(placeId)
        Task { await BusinessService.recordView(placeId: placeId) }
    }

    private var headerTitle: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
    }

    /// What the user actually typed, if anything. Auto categories arrive with a
    /// synthetic Places query ("auto repair and maintenance shop") in
    /// `searchQuery` — that's routing input, not the user's words, so it never
    /// pre-fills the quote-request text.
    private var typedQuery: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if autoCategoryItems.contains(where: {
            $0.searchQuery.caseInsensitiveCompare(q) == .orderedSame
                || $0.motoSearchQuery.caseInsensitiveCompare(q) == .orderedSame
        }) { return "" }
        return q
    }

    /// Term source for photo ordering — the typed query, else the category, so a
    /// plain category browse still leads with its best-matching photos.
    private var orderQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? category : searchQuery
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
                        stripBottomPadding: collapsedSheetH + 12,
                        // The contractor opened from the list starts on the exact
                        // photo that was tapped there; everyone else on the first.
                        initialIndex: contractor.id == startContractorID ? startPhotoIndex : 0
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

                    // ── Pinned Call / Request quote — equal sizes ─────────────
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
            // Opened via a reviews link → surface the reviews sheet expanded.
            if startReviewsExpanded { sheetDetent = .full }
            await loadContractors()
            totalCount = contractors.count
        }
        // Screen the current contractor + the next couple ahead of time, so the
        // photo is ready the instant a contractor is surfaced (no load stall).
        .task(id: topContractor?.id) { await prefetchUpcoming() }
        // Keep the List view's restore target in step with the contractor on top.
        .onChange(of: topContractor?.id, initial: true) { _, id in
            if let id {
                lastViewedID?.wrappedValue = id
                recordView(placeId: id)
            }
        }
        .navigationDestination(isPresented: $showQuote) {
            QuoteRequestScreen(contractor: selectedContractor, requestSummary: typedQuery, initialImages: attachedImages, clarifyTranscript: clarifyTranscript)
        }
        .sheet(isPresented: $showCallReminder) {
            if let contractor = topContractor {
                CallReminderSheet(contractor: contractor) {
                    showCallReminder = false
                    call(contractor)
                }
            }
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
                    ForEach(Array(orderedReviews(for: contractor).prefix(5))) { ReviewRowGallery(review: $0) }
                    // End of the in-app reviews → link out to the full set on Google.
                    if contractor.reviewCount > 0 {
                        allReviewsLink(for: contractor)
                    }
                }
                // Clear the pinned CTAs at the bottom — at least 160pt so the last
                // row (e.g. the "All reviews" link) is never hidden behind them.
                Color.clear.frame(height: 160 + bottomInset)
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

    /// Reviews ordered so the one describing the searched job leads — e.g.
    /// searching "vanity cabinet" surfaces reviews about that first. Falls back to
    /// original order when the query has no subject term (a plain category browse).
    ///
    /// `pinnedReviewID` then overrides that ordering. Both screens used to derive
    /// their own query string and rely on the two agreeing; they don't in every
    /// case (this screen falls back to `searchQuery`/`category`, the list card
    /// deliberately does not), so the quoted review could sort first on the card
    /// and mid-list here. Carrying the identity makes the match exact instead of
    /// coincidental. `firstIndex` is scoped to this contractor's own reviews, so a
    /// pin from the list can't disturb any other business in the stack.
    private func orderedReviews(for contractor: Contractor) -> [Review] {
        let ordered = PhotoFilter.orderReviewsByJob(contractor.reviews, query: reviewMatchQuery,
                                                    text: { $0.text })
        guard let pinnedReviewID,
              let idx = ordered.firstIndex(where: { $0.id == pinnedReviewID })
        else { return ordered }
        var rest = ordered
        let lead = rest.remove(at: idx)
        return [lead] + rest
    }

    /// The query that decides review relevance — the chat's `photo_terms` when
    /// present (mirrors the list's `matchQuery`), else the search query, else the
    /// category. Keeps the sheet's lead review aligned with the list card's quote.
    private var reviewMatchQuery: String {
        let terms = photoMatchTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { return terms }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
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
                // A single star icon + the aggregate rating and count — the full
                // five-star row was redundant here; the link out to Google's full
                // review set lives at the END of the sheet (see `allReviewsLink`).
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(AppColors.starFilled)
                    Text("\(contractor.rating, specifier: "%.1f") • \(contractor.reviewCount) reviews")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    // "All reviews" — the link to the contractor's full Google review set, shown
    // once the user has scrolled past the in-app reviews at the bottom of the sheet.
    private func allReviewsLink(for contractor: Contractor) -> some View {
        Button {
            if let url = googleReviewsURL(for: contractor) { openURL(url) }
        } label: {
            HStack(spacing: 6) {
                Text("All reviews")
                    .font(.h4)
                    .foregroundStyle(.white)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .secondaryButtonBackground()
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    /// Deep link to the contractor's Google reviews. `id` is the Google place id
    /// on the live path (mock contractors won't resolve, which is fine here).
    private func googleReviewsURL(for contractor: Contractor) -> URL? {
        URL(string: "https://search.google.com/local/reviews?placeid=\(contractor.id)")
    }

    // Pinned Call / Request quote — equal-width buttons on a fading floor
    // (Figma "CTAs": two 48pt-tall buttons, radius 32, 8pt gap).
    private func ctaFooter(width: CGFloat, bottomInset: CGFloat) -> some View {
        // Exact equal widths from the known screen width — no reliance on the
        // parent's width proposal (which has overflowed past the screen edges).
        let buttonWidth = max(0, (width - 32 - 8) / 2)
        let hasPhone = topContractor?.phone != nil
        return HStack(spacing: 8) {
            // Call replaces the old "Next": tapping shows a reminder to mention
            // the app, then hands off to the dialer. Dimmed when Places returned
            // no phone number for this business.
            Button(action: { showCallReminder = true }) {
                Text("Call")
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
                    .opacity(hasPhone ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!hasPhone)

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

    /// Hands off to the system dialer with the business's number pre-filled (the
    /// OS shows its own call confirmation — we never place the call ourselves).
    private func call(_ contractor: Contractor) {
        guard let phone = contractor.phone else { return }
        // Places returns a display-formatted number ("(415) 555-0132"); tel: URLs
        // only accept digits and a leading +.
        let dialable = phone.filter { $0.isNumber || $0 == "+" }
        guard !dialable.isEmpty, let url = URL(string: "tel:\(dialable)") else { return }
        openURL(url)
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
                let ordered = PhotoFilter.order(v.kept, query: orderQuery, capPremises: galleryPremisesCap)
                screenedByID[contractor.id] = ordered
                if ordered.isEmpty {
                    contractors.removeAll { $0.id == contractor.id }
                    if totalCount > 0 { totalCount -= 1 }
                } else if let first = ordered.first, let u = URL(string: first) {
                    await ImageCache.shared.prefetch(u)
                    // Verdict cached before rich tagging → sharpen its order now.
                    if !v.enriched {
                        enrichInBackground(contractor.id, kept: v.kept, scanned: v.scanned,
                                           allowVehicles: allowVehicles)
                    }
                }
                continue
            }
            // Shared verdict from another user — reuse, no download.
            if let v = await VerdictService.fetch(ids: [contractor.id], allowVehicles: allowVehicles)[contractor.id] {
                ScreeningStore.shared.save(contractor.id, allowVehicles: allowVehicles,
                                           kept: v.kept, scanned: v.scanned, enriched: v.enriched)
                let ordered = PhotoFilter.order(v.kept, query: orderQuery, capPremises: galleryPremisesCap)
                screenedByID[contractor.id] = ordered
                if ordered.isEmpty {
                    contractors.removeAll { $0.id == contractor.id }
                    if totalCount > 0 { totalCount -= 1 }
                } else if let first = ordered.first, let u = URL(string: first) {
                    await ImageCache.shared.prefetch(u)
                    if !v.enriched {
                        enrichInBackground(contractor.id, kept: v.kept, scanned: v.scanned,
                                           allowVehicles: allowVehicles)
                    }
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
            let ordered = PhotoFilter.order(kept, query: orderQuery, capPremises: galleryPremisesCap)
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
            // Sharpen the order with rich vision tags in the background (these
            // paginated businesses were never in the list, so they're screened
            // fresh here); the photo is already showing on the on-device ordering.
            enrichInBackground(contractor.id, kept: kept, scanned: scanned, allowVehicles: allowVehicles)
        }
        // Surface a fuller set of work photos for the business now on top:
        // deepen the Places pool, then lead with the business's own website photos.
        if let top = topContractor {
            await deepenPhotos(for: top)
            await mergeWebsitePhotos(for: top)
        }
        // Dropping no-photo businesses can thin the stack — top up if we can.
        loadMoreIfNeeded()
    }

    /// Merge the business's OWN website photos (free, zero-consent enrichment via
    /// the `business-photos` function) ahead of the Places pool. These are NOT
    /// trusted blindly — a site's hero image is very often a logo, a cartoon van
    /// wrap, or the storefront — so they run through the SAME on-device work-photo
    /// screening as Places (which rejects logos/signage/vehicles/people/text-heavy
    /// shots) and the same premises cap. Only genuine work photos survive to lead
    /// the gallery. One call per business per session (the function caches across
    /// users, so the external website fetch happens once per business overall).
    @MainActor
    private func mergeWebsitePhotos(for contractor: Contractor) async {
        guard !websiteFetched.contains(contractor.id) else { return }
        websiteFetched.insert(contractor.id)
        let urls = await BusinessPhotoService.fetch(placeId: contractor.id, website: contractor.website)
        guard !urls.isEmpty, contractors.contains(where: { $0.id == contractor.id }) else { return }
        // Screen them the same way as Places photos, so clipart/logos/storefronts
        // from the site get rejected instead of leading the gallery.
        let allowVehicles = isAutoService(category: category, searchQuery: searchQuery)
        let screened = await PhotoFilter.screen(urls, allowVehicles: allowVehicles,
                                                limit: urls.count, scanLimit: urls.count)
        let website = PhotoFilter.order(screened, query: orderQuery, capPremises: galleryPremisesCap)
        guard !website.isEmpty, contractors.contains(where: { $0.id == contractor.id }) else { return }
        let existing = screenedByID[contractor.id] ?? []
        let have = Set(existing)
        let fresh = website.filter { !have.contains($0) }
        guard !fresh.isEmpty else { return }
        // Business's own (screened) work photos first, then the Places work photos.
        screenedByID[contractor.id] = fresh + existing
        // Warm the first one so the swap to a website work photo is instant.
        if let first = fresh.first, let u = URL(string: first) {
            await ImageCache.shared.prefetch(u)
        }
    }

    /// Surface a fuller set of work photos for the business on top. The list only
    /// screens a few per business (its mosaic needs three), so a hand-off arrives
    /// thin. Here — where the user actually browses — we screen the REST of this
    /// business's own pool (only the one being viewed, so photo downloads stay
    /// bounded) so every genuine work photo the filter accepts surfaces, up to
    /// `galleryMaxKept`. We deliberately do NOT pad to a count with unscreened
    /// photos: a business with only 4 real work shots shows 4, never 4 + a run of
    /// storefronts/logos/office exteriors. Premises shots are additionally capped
    /// in the ordering so a legit exterior appears at most once.
    @MainActor
    private func deepenPhotos(for contractor: Contractor) async {
        let current = screenedByID[contractor.id] ?? []
        guard current.count < galleryMinPhotos,
              current.count < contractor.photos.count else { return }
        let allowVehicles = isAutoService(category: category, searchQuery: searchQuery)
        // How far the pool has already been scanned (persisted by the list
        // hand-off or an earlier gallery pass).
        let verdict = ScreeningStore.shared.get(contractor.id, allowVehicles: allowVehicles)
        var kept = verdict?.kept ?? []
        let scanned = verdict?.scanned ?? kept.count

        // 1. Screen whatever's left of the pool, so ranking sees every work photo.
        if scanned < contractor.photos.count {
            let remaining = Array(contractor.photos.dropFirst(scanned))
            let more = await PhotoFilter.screen(remaining, allowVehicles: allowVehicles,
                                                limit: galleryMaxKept, scanLimit: remaining.count)
            // The stack may have changed (paged past, Auto⇄Moto) while scanning.
            guard contractors.contains(where: { $0.id == contractor.id }) else { return }
            kept = Array((kept + more).prefix(galleryMaxKept))
            let newScanned = contractor.photos.count
            ScreeningStore.shared.save(contractor.id, allowVehicles: allowVehicles,
                                       kept: kept, scanned: newScanned,
                                       enriched: verdict?.enriched ?? false)
            VerdictService.upload(id: contractor.id, allowVehicles: allowVehicles,
                                  kept: kept, scanned: newScanned, enriched: verdict?.enriched ?? false)
        }

        // 2. Show only screened work photos, query-ranked, with premises
        // (storefront/office/house-exterior) shots capped so they can't fill the
        // strip. No padding with unscreened photos — quality over hitting a count,
        // so a business with only 4 real work photos shows 4, not 4 + 6 storefronts.
        let ordered = PhotoFilter.order(kept, query: orderQuery, capPremises: galleryPremisesCap)
        guard contractors.contains(where: { $0.id == contractor.id }) else { return }
        if !ordered.isEmpty { screenedByID[contractor.id] = ordered }
    }

    /// Ask the vision model for rich, query-independent tags for a freshly-screened
    /// business's photos, then re-order and re-share the enriched verdict. On-device
    /// labels are only generic scene tokens (no "bumper", no car make), so query
    /// ranking can't otherwise work for auto or specific home searches. Detached so
    /// the photo shows immediately; this only refines the order a beat later.
    private func enrichInBackground(_ id: String, kept: [ScreenedPhoto],
                                    scanned: Int, allowVehicles: Bool) {
        Task { @MainActor in
            // nil = tagger didn't run → leave un-enriched so a later visit retries.
            guard let enriched = await PhotoTagService.enrich(kept, allowVehicles: allowVehicles),
                  contractors.contains(where: { $0.id == id }) else { return }
            // Re-order only when the tags changed the labels; either way mark the
            // verdict enriched so it isn't re-tagged on every visit.
            if enriched != kept {
                screenedByID[id] = PhotoFilter.order(enriched, query: orderQuery, capPremises: galleryPremisesCap)
            }
            ScreeningStore.shared.save(id, allowVehicles: allowVehicles, kept: enriched,
                                       scanned: scanned, enriched: true)
            VerdictService.upload(id: id, allowVehicles: allowVehicles, kept: enriched,
                                  scanned: scanned, enriched: true)
        }
    }

    // ── Data loading (mirrors SwipeScreen) ────────────────────────────────────
    @MainActor
    private func loadContractors() async {
        guard contractors.isEmpty else { return }

        // Handed over from the List view — reuse its contractors and screened
        // photos verbatim, surfacing the tapped contractor first.
        if let preloaded = preloadedContractors {
            screenedByID = preScreened
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
            contractors = page.contractors
            nextPageToken = page.nextPageToken
            pagingCoord = coord
            return
        }
        // Only with no resolvable location at all (denied / offline) do we show
        // the built-in demo contractors.
        contractors = ContractorLoader.fallback(category: category, searchQuery: searchQuery)
    }
}

/// Screening budget for contractors that reach the gallery via pagination (the
/// rest reuse the list's screening). The gallery is where the user browses work,
/// so it keeps a fuller set than the list mosaic does.
private let galleryMaxKept = 12
private let galleryScanLimit = 10
/// Target number of work photos to surface for the business being viewed. The
/// list only screens a few per business; `deepenPhotos` tops the viewed one up
/// to this by screening the rest of its own pool.
private let galleryMinPhotos = 10
/// Max premises shots (storefront / office / house exterior) the gallery keeps
/// once a business also has real work photos — so a business's building/signage
/// can appear at most this many times instead of filling the strip. Slightly
/// looser than the list's cap of 1, since browsing the gallery has more room.
private let galleryPremisesCap = 2

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

    @State private var photoIndex: Int
    /// The photo tapped for full-screen zoom (nil = viewer closed).
    @State private var zoomItem: ZoomItem? = nil

    init(photos: [String]?, width: CGFloat, imageHeight: CGFloat,
         stripBottomPadding: CGFloat, initialIndex: Int = 0) {
        self.photos = photos
        self.width = width
        self.imageHeight = imageHeight
        self.stripBottomPadding = stripBottomPadding
        // Clamp so a stale index from the list can never point past the stack.
        let count = photos?.count ?? 0
        _photoIndex = State(initialValue: count > 0 ? min(max(initialIndex, 0), count - 1) : 0)
    }

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
                        .onTapGesture { if photoURL != nil { zoomItem = ZoomItem(index: photoIndex) } }
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
            PhotoZoomViewer(
                photos: shownPhotos,
                initialIndex: item.index,
                onClose: { zoomItem = nil },
                // Keep the gallery photo + thumbnail strip in step with the
                // viewer, so closing it lands on the photo the user paged to.
                onIndexChange: { photoIndex = $0 })
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
// instantly. Double-tap toggles zoom. When not zoomed in, a sideways swipe pages
// through the same photo stack the gallery shows (wraps around, like the
// gallery's own swipe); while zoomed in, the drag pans instead.
// ─────────────────────────────────────────────────────────────────────────────

/// Identifiable wrapper so the tapped photo drives a `fullScreenCover(item:)`.
private struct ZoomItem: Identifiable {
    let id = UUID()
    let index: Int
}

private struct PhotoZoomViewer: View {
    let photos: [String]
    let onClose: () -> Void
    /// Fired on every page so the gallery underneath stays on the same photo.
    let onIndexChange: (Int) -> Void

    @State private var index: Int
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Live downward drag for pull-to-dismiss (only when not zoomed in).
    @State private var dismissOffset: CGFloat = 0

    private let maxScale: CGFloat = 4
    /// How far into the dismiss pull we are, 0…1 — fades the backdrop and shrinks
    /// the photo so the gesture reads as "letting go closes it".
    private var dismissProgress: CGFloat { min(max(dismissOffset, 0) / 240, 1) }

    init(photos: [String], initialIndex: Int,
         onClose: @escaping () -> Void,
         onIndexChange: @escaping (Int) -> Void = { _ in }) {
        self.photos = photos
        self.onClose = onClose
        self.onIndexChange = onIndexChange
        _index = State(initialValue: initialIndex)
    }

    private var url: URL? {
        photos.indices.contains(index) ? URL(string: photos[index]) : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Backdrop fades as the photo is pulled down, revealing the gallery
            // beneath and signalling the pending dismiss.
            Color.black.opacity(1 - dismissProgress * 0.6).ignoresSafeArea()

            PlacesImage(url: url) { Color.clear }
                .scaledToFit()
                // The dismiss pull shrinks the photo slightly (only when not zoomed).
                .scaleEffect(scale * pinch * (scale <= 1 ? 1 - dismissProgress * 0.15 : 1))
                .offset(x: offset.width, y: offset.height + dismissOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .id(index)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: index)
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
                            if scale > 1 {
                                offset = CGSize(width: lastOffset.width + v.translation.width,
                                                height: lastOffset.height + v.translation.height)
                            } else if v.translation.height > 0,
                                      abs(v.translation.height) > abs(v.translation.width) {
                                // Not zoomed + downward-dominant → live pull-to-dismiss.
                                dismissOffset = v.translation.height
                            }
                        }
                        .onEnded { v in
                            if scale > 1 { lastOffset = offset; return }
                            let horizontal = abs(v.translation.width) > abs(v.translation.height)
                            if !horizontal {
                                // Vertical drag: a far-enough pull or a downward flick
                                // dismisses; otherwise the photo springs back.
                                if v.translation.height > 120 || v.predictedEndTranslation.height > 320 {
                                    onClose()
                                } else {
                                    withAnimation(.easeOut(duration: 0.2)) { dismissOffset = 0 }
                                }
                                return
                            }
                            // Horizontal-dominant swipe pages, same threshold as the gallery.
                            withAnimation(.easeOut(duration: 0.2)) { dismissOffset = 0 }
                            guard abs(v.translation.width) > 40 else { return }
                            page(v.translation.width < 0 ? 1 : -1)   // swipe left → next
                        }
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

    /// Step to the next/previous photo (wraps around) and reset any zoom/pan so
    /// the new photo opens at its natural fit.
    private func page(_ dir: Int) {
        let count = photos.count
        guard count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            index = (index + dir + count) % count
            scale = 1
            offset = .zero
            lastOffset = .zero
            dismissOffset = 0
        }
        onIndexChange(index)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GalleryHeader
// Matches the main screen's top bar: horizontal 16 / vertical 8 padding over the
// shared BlurredHeaderBackground.
// ─────────────────────────────────────────────────────────────────────────────

private struct GalleryHeader: View {
    let title: String
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

            Text(title)
                .font(.h2)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
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
// MARK: - CallReminderSheet
// Bottom sheet shown before dialing: a nudge to say the request came from
// Brightglow, with a single primary Call action. The actual call is never placed
// here — Call hands off to the system dialer, which shows its own confirmation
// with the number pre-filled.
// ─────────────────────────────────────────────────────────────────────────────

private struct CallReminderSheet: View {
    let contractor: Contractor
    /// Fired by the Call button — the screen dismisses this sheet and dials.
    let onCall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Before you call")
                .font(.h2)
                .foregroundStyle(.white)

            Text("When they pick up, mention you found them on Brightglow — so \(contractor.name) knows your request came from the app.")
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.5))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Button(action: onCall) {
                Text("Call")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(AppColors.btnPrimary,
                                in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.height(236)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColors.bg)
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
