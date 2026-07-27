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
    /// The vertical the clarifying chat resolved ("home" / "auto_moto"), empty
    /// when no chat ran. Everything below infers the vertical from the category
    /// NAME, and the Auto & moto vertical owns the generic word "Repair" — so a
    /// home request the model labelled "Repair" opened a car-shop list, complete
    /// with an Auto/Moto toggle ("fix fridge", reported live 2026-07-22). An
    /// explicit "home" outranks the inference; empty leaves it untouched.
    var clarifyVertical: String = ""
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
    /// The landing clarifying Q&A, carried through to the quote-request screen so
    /// the message a business receives includes the AI-clarified details.
    var clarifyTranscript: ClarifyTranscript = .empty

    init(category: String = "",
         clarifyVertical: String = "",
         searchQuery: String = "",
         aiResult: AIResult? = nil,
         presetCoordinate: CLLocationCoordinate2D? = nil,
         attachedImages: [UIImage] = [],
         photoDetails: String? = nil,
         businessSearchOverride: String = "",
         photoMatchTerms: String = "",
         priceable: Bool = true,
         clarifyTranscript: ClarifyTranscript = .empty,
         initialVehicle: VehicleFilter? = nil) {
        self.category = category
        self.clarifyVertical = clarifyVertical
        self.searchQuery = searchQuery
        self.aiResult = aiResult
        self.presetCoordinate = presetCoordinate
        self.attachedImages = attachedImages
        self.photoDetails = photoDetails
        self.businessSearchOverride = businessSearchOverride
        self.photoMatchTerms = photoMatchTerms
        self.priceable = priceable
        self.clarifyTranscript = clarifyTranscript
        // Moto vs car for the Auto & moto toggle: an explicit signal (a
        // motorcycle detected in the captured photo) wins; otherwise sniff the
        // query text so a moto-specific search ("motorcycle brakes") opens on
        // the Moto side. Defaults to cars.
        let resolved: VehicleFilter
        if let initialVehicle {
            resolved = initialVehicle
        } else {
            let hay = (searchQuery + " " + businessSearchOverride + " " + photoMatchTerms).lowercased()
            let motoTerms = ["motorcycle", "motorbike", "moped", "scooter", "dirt bike", "sportbike"]
            resolved = motoTerms.contains(where: hay.contains) ? .moto : .auto
        }
        _vehicle = State(initialValue: resolved)
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    /// The business whose row "Call" was tapped — drives the shared "Before you
    /// call" reminder sheet before we hand off to the dialer. Same pop-up the
    /// gallery shows, so the mention-Brightglow nudge appears wherever Call lives.
    @State private var callContractor: Contractor? = nil
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
    /// Set when the gallery is opened from a row's "N reviews" link, so it lands
    /// with the reviews sheet expanded rather than the default collapsed peek.
    @State private var startReviewsExpanded = false
    @State private var startContractorID: String? = nil
    /// The review quoted on the row the user opened, pinned to the top of the
    /// gallery's reviews sheet. Cleared when opening by any other route.
    @State private var pinnedReviewID: String? = nil
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
    /// A business's OWN uploaded photos (from the app's Settings editor), by id.
    /// Owner-curated, so they lead the strip un-screened and keep a claimed
    /// business visible even when Google returns no usable work photos for it.
    @State private var ownerPhotosByID: [String: [String]] = [:]
    /// Active contractor licences (CSLB), by contractor id. Absence means
    /// "unknown" — CSLB is California-only — never "unlicensed", so a missing
    /// entry shows no badge rather than a negative one.
    @State private var licenseByID: [String: LicenseService.License] = [:]

    /// Hosted logo URLs by contractor id, filled best-effort after load. A
    /// business not present here draws a name monogram (see [[LogoService]]).
    @State private var logoByID: [String: URL] = [:]
    /// How many of the (relevance-ranked) contractors are shown. Starts at the
    /// best-matching `initialVisibleCount`; "See more" reveals the rest.
    @State private var visibleLimit = initialVisibleCount
    /// True while "See more" is fetching another page from Places.
    @State private var isLoadingMore = false

    private var headerTitle: String {
        // Auto & moto: show the exact category name the user tapped ("Repair",
        // "Body & Paint") so the header matches the grid card and stays stable
        // when the Auto ⇄ Moto toggle is flipped. The toggle communicates the
        // vehicle; never surface the raw Places query.
        if let auto = autoCategory {
            return auto.name
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
    }

    /// The Auto & moto category being viewed, if any (drives the vehicle filter).
    /// A chat that resolved the request as a home trade vetoes the match: the
    /// category names overlap across verticals, the vertical itself doesn't.
    private var autoCategory: AutoCategory? {
        guard clarifyVertical != "home" else { return nil }
        return autoCategoryItems.first { $0.name == category }
    }

    /// Whether vehicle photos count as work photos for this search. Same veto as
    /// `autoCategory`, and needed separately because `isAutoService` also matches
    /// on the query text — "refrigerator repair service" hits the Repair
    /// keywords, which would keep car photos on an appliance search.
    private func allowsVehiclePhotos(_ query: String) -> Bool {
        guard clarifyVertical != "home" else { return false }
        return isAutoService(category: category, searchQuery: query)
    }

    /// Query actually sent to Places — the moto variant when the filter is on
    /// Moto, else the chat's refined `search_terms` when present, else the raw
    /// query. (The auto vehicle toggle owns the query for auto services, so the
    /// override only applies to home searches.)
    private var effectiveSearchQuery: String {
        if let auto = autoCategory { return auto.query(for: vehicle) }
        let override = businessSearchOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? searchQuery : override
    }

    /// What the pricing engine classifies and sizes the job from.
    ///
    /// `effectiveSearchQuery` is the right phrase to find BUSINESSES with, but
    /// for an auto category it is a synthetic Places query ("tire shop") that
    /// carries nothing about the request — so "Replace 4 tires on a Model 3,
    /// all-season" was being priced from the words "tire shop", losing both the
    /// count and any grade signal (`resolveQuantity` and `qualityTier` both read
    /// this string). Send the user's own words instead; an empty result means a
    /// bare category browse, which the server answers with its typical-job
    /// figure. Home is untouched — there `effectiveSearchQuery` is already
    /// either the chat's refined phrase or the raw typed text.
    private var pricingDescription: String {
        guard let auto = autoCategory else { return effectiveSearchQuery }
        let typed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // A grid-card tap puts the synthetic phrase in `searchQuery`; a search
        // puts the user's request there. Only the latter describes a job.
        let synthetic = [auto.searchQuery.lowercased(), auto.motoSearchQuery.lowercased()]
        return synthetic.contains(typed.lowercased()) ? "" : typed
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

    /// Query used solely to decide the "Did similar job" badge — real user intent
    /// only: the chat's `photo_terms`, else a chat-refined search (home only, like
    /// `effectiveSearchQuery`), else what the user actually typed. Deliberately
    /// omits the bare-category / synthetic auto-category fallback that `orderQuery`
    /// uses, so simply opening a category with no input shows no badge (empty →
    /// `PhotoFilter.matchesQuery` returns false).
    private var matchQuery: String {
        let terms = photoMatchTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { return terms }
        let override = businessSearchOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if autoCategory == nil, !override.isEmpty { return override }
        return typedQuery
    }

    /// The rows actually rendered — ranked by match STRENGTH, strongest first,
    /// then the top of the upstream list. A similar-job match outranks every
    /// free-signal heuristic in PlacesService's ordering (north star: similar-job
    /// > proximity > rating), but not all matches are equal: a business that both
    /// shows the work AND is praised for it should beat one whose only hit is a
    /// review mention (its photos may not match the ask). So instead of one flat
    /// "similar" group, businesses sort by `matchRank`, each tier keeping its
    /// upstream order. Proof arrives progressively — cached/shared verdicts at
    /// load, then per row as lazy screening completes — so the order refines over
    /// time (a review-only match climbs to the top tier once its photo is screened
    /// and confirmed).
    private var visibleContractors: [Contractor] {
        let ranked = contractors.enumerated()
            .map { (offset: $0.offset, contractor: $0.element, rank: matchRank($0.element)) }
            .sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.offset < $1.offset }
            .map(\.contractor)
        return Array(ranked.prefix(visibleLimit))
    }

    /// Match strength driving promotion. Two independent proofs, weighted so the
    /// *work being visible* outranks words about it: +2 for a screened work photo
    /// of the job, +1 for a review naming it. Both → 3 (leads), photo-only → 2,
    /// review-only → 1, neither → 0. The review path needs no photo screening, so
    /// a matching specialist deep in the list still surfaces without our paying to
    /// screen everything down to it — then rises to the top tier once its row is
    /// revealed and the photo confirms.
    private func matchRank(_ c: Contractor) -> Int {
        let photo = PhotoFilter.matchesQuery(keptPhotos[c.id] ?? [], query: matchQuery) ? 2 : 0
        let review = PhotoFilter.reviewsMentionJob(c.reviews.map(\.text), query: matchQuery) ? 1 : 0
        return photo + review
    }

    /// Single source of truth for the similar-job signal — drives the row's
    /// "Did similar job" badge. Any proof (photo or review) earns it.
    private func didSimilarJob(_ c: Contractor) -> Bool { matchRank(c) > 0 }

    /// The customer review that best describes the searched job, shown on the row
    /// as the "why" behind a match. Nil when no review mentions it (or on a bare
    /// category browse, where `matchQuery` has no subject term).
    private func matchingReview(_ c: Contractor) -> String? {
        PhotoFilter.mostRelevantReview(c.reviews.map(\.text), query: matchQuery)
    }

    /// Identity of the review `matchingReview` quoted, handed to the gallery so
    /// the sheet leads with that exact comment. The quote is a sentence pulled
    /// from mid-review, so it can't be matched by text on the other side.
    private func matchingReviewID(_ c: Contractor) -> String? {
        PhotoFilter.mostRelevantReviewIndex(c.reviews.map(\.text), query: matchQuery)
            .map { c.reviews[$0].id }
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
                attachedImages: attachedImages,
                startReviewsExpanded: startReviewsExpanded,
                photoMatchTerms: photoMatchTerms,
                pinnedReviewID: pinnedReviewID,
                clarifyTranscript: clarifyTranscript
            )
        }
        .navigationDestination(item: $quoteContractorID) { id in
            // Same consent/review step the gallery uses, aimed at the business
            // whose row CTA was tapped.
            QuoteRequestScreen(
                contractor: contractors.first { $0.id == id },
                requestSummary: typedQuery,
                initialImages: attachedImages,
                clarifyTranscript: clarifyTranscript
            )
        }
        // Custom bottom overlay (same as the gallery) so the card is a flush,
        // full-width bottom sheet rather than iOS 26's inset floating card.
        .overlay {
            if let contractor = callContractor {
                CallReminderSheet(contractor: contractor) {
                    callContractor = nil
                    dial(contractor)
                } onDismiss: {
                    callContractor = nil
                }
            }
        }
        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: callContractor?.id)
        .alert("How we estimate", isPresented: $showEstimateInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(estimateInfoText)
        }
    }

    /// Hands off to the system dialer with the business's number pre-filled (the
    /// OS shows its own call confirmation — we never place the call ourselves).
    private func dial(_ contractor: Contractor) {
        guard let phone = contractor.phone else { return }
        let dialable = phone.filter { $0.isNumber || $0 == "+" }
        guard !dialable.isEmpty, let url = URL(string: "tel:\(dialable)") else { return }
        openURL(url)
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
                            licenseNo: licenseByID[contractor.id]?.licenseNo,
                            // "Did similar job": the business has a screened work
                            // photo matching this request (design brief §9). Uses
                            // `matchQuery` (real user intent only), so a bare category
                            // browse with no input never shows the badge.
                            didSimilarJob: didSimilarJob(contractor),
                            // The customer's own words about this job — shown as
                            // the "why" when a review names the searched work.
                            matchingReview: matchingReview(contractor),
                            logoURL: logoByID[contractor.id],
                            onOpen: { photoIndex in open(contractor, photoIndex: photoIndex) },
                            onReviews: { openReviews(for: contractor) },
                            onQuote: { quoteContractorID = contractor.id },
                            onCall: { callContractor = contractor }
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

                    if hasMore { loadMoreTrigger }
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

    // ── Infinite scroll — reveals held-back matches, then pages, on approach ───
    // Replaces the old "See more" button: this sentinel sits at the tail of the
    // list and, when it scrolls into view, pulls the next batch. Cost is
    // unchanged — photos still screen lazily per row (see `screenIfNeeded`), so
    // revealing/paging only downloads photos for rows the user actually reaches;
    // the sentinel only removes the extra tap, it doesn't screen ahead.
    private var loadMoreTrigger: some View {
        HStack {
            if isLoadingMore { ProgressView().tint(.white) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .padding(.top, 8)
        // Fires as the tail is approached. showMore() self-guards against
        // re-entrancy and no-ops once there's nothing left, so repeated
        // appearances are safe.
        .onAppear { Task { await showMore() } }
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

    /// Header price line — one calm, rounded number: "Typically around $1.5k".
    /// Falls back to the plain range only for sources with no central estimate
    /// (mocks / permit-only), which have no typical to lead with.
    private func headerEstimateText(_ tier: PriceTier) -> String {
        if let typical = tier.typical {
            let amount = "~$\(money(roundSig2(typical)))"
            // Labor-only figures MUST carry the qualifier — the same number
            // unlabelled would read as the whole job (pilot, 2026-07-16).
            return tier.laborOnly ? "Typically \(amount) labor only" : "Typically \(amount)"
        }
        return "Est prices: $\(money(tier.min))–\(money(tier.max))"
    }

    /// The info-icon explainer — where the full range lives now that the header
    /// shows a single number. Kept plain-spoken; the spread is framed as "what
    /// most jobs cost", with the drivers named so a number outside it doesn't
    /// read as us being wrong.
    private var estimateInfoText: String {
        guard let tier = estimate else {
            return "A typical price range for this job in your area. The business gives you the final quote."
        }
        let range = "$\(money(roundSig2(tier.min)))–$\(money(roundSig2(tier.max)))"
        // Labor-only: we don't model this job's parts, so the modal states the
        // basis (hours x local rate, carried in the server's label) and is
        // explicit that parts are excluded — never implies an all-in price.
        if tier.laborOnly {
            return "We don't have parts pricing for this job yet, so this covers labor only — "
                + "most visits land between \(range). \(tier.label) "
                + "The business gives you the final quote."
        }
        if let typical = tier.typical {
            return "Typically ~$\(money(roundSig2(typical))) for this job in your area. "
                + "Most jobs land between \(range), depending on size and materials. "
                + "The business gives you the final quote."
        }
        return "Most jobs land between \(range), depending on size and materials. "
            + "The business gives you the final quote."
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
                        Text(headerEstimateText(tier))
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
        startReviewsExpanded = false
        pinnedReviewID = matchingReviewID(contractor)
        goGallery = true
    }

    /// The "N reviews" link opens the gallery for this contractor with its bottom
    /// sheet expanded to the reviews (in-app), rather than jumping straight out to
    /// Google — the Google link now lives at the end of that sheet.
    ///
    /// Also the destination for tapping the quoted review on the row, which is why
    /// the quoted review is pinned to the top of the sheet: the user tapped that
    /// comment and it must be the first one waiting for them.
    private func openReviews(for contractor: Contractor) {
        startContractorID = contractor.id
        startPhotoIndex = 0
        startReviewsExpanded = true
        pinnedReviewID = matchingReviewID(contractor)
        goGallery = true
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
            let allowVehicles = allowsVehiclePhotos(query)
            for c in contractors {
                guard let v = ScreeningStore.shared.get(c.id, allowVehicles: allowVehicles) else { continue }
                if !v.kept.isEmpty {
                    // Cached work photos → show them, ordered by the current query.
                    keptPhotos[c.id] = v.kept
                    screenedByID[c.id] = PhotoFilter.order(v.kept, query: orderQuery,
                                                           capPremises: stripMaxPremises)
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
                    screenedByID[id] = PhotoFilter.order(v.kept, query: orderQuery,
                                                         capPremises: stripMaxPremises)
                    if !v.enriched { needsEnrich.insert(id) }
                }
                ScreeningStore.shared.save(id, allowVehicles: allowVehicles,
                                           kept: v.kept, scanned: v.scanned, enriched: v.enriched)
            }

            // Lead each business with its OWN uploaded photos (cheap: one query,
            // and only claimed businesses come back). Done before the drop below so
            // a business that uploaded photos stays even when Google gives us none.
            await loadOwnerPhotos(for: contractors)

            // Drop businesses confirmed to have no work photos in their whole pool,
            // so they don't reappear as blank rows on a later visit. A business with
            // its own uploaded photos is exempt — it has something real to show.
            contractors.removeAll { c in
                ownerPhotosByID[c.id] == nil
                    && (scannedCount[c.id] ?? 0) >= c.photos.count
                    && (screenedByID[c.id]?.isEmpty ?? true)
            }
            // Uncovered categories stay match-only — the price line shows the
            // "coming soon" state (with a real business count) instead. Auto &
            // moto is no longer among them; it passes its vehicle filter so a
            // bike isn't priced as a car.
            if !contractors.isEmpty && priceable {
                Task { @MainActor in
                    estimate = await ContractorLoader.estimate(
                        category: category, searchQuery: pricingDescription, near: coord,
                        photoDetails: photoDetails,
                        vehicle: allowVehicles ? vehicle : nil)
                }
            }
        } else {
            contractors = ContractorLoader.fallback(
                category: category, searchQuery: query)
        }
        isLoading = false
        // Photos are screened lazily per row (see `screenIfNeeded`) so we only pay
        // for the businesses the user actually scrolls to. Exception: eagerly
        // screen the top slice now so "did a similar job" is known for the
        // visible window and those businesses lead from the first render, not
        // only once their row happens to scroll into view.
        eagerlyScreenTopMatches()
        await loadLicenses(for: contractors)
        await loadLogos(for: contractors)
    }

    /// Kick off the cheap list-pass screening for the top `eagerScreenDepth`
    /// businesses (those not already primed from a cached/shared verdict), so
    /// the similar-job signal that drives promotion is resolved for the
    /// visible window without waiting on scroll. Reuses `screenIfNeeded`, so
    /// it shares the same dedupe, cost budget, and verdict caching/sharing as
    /// lazy screening — no extra Places Photo requests beyond what scrolling
    /// the first page would have cost anyway, just front-loaded. Non-blocking:
    /// each promotion lands as its screening completes.
    @MainActor
    private func eagerlyScreenTopMatches() {
        for c in contractors.prefix(eagerScreenDepth) where scannedCount[c.id] == nil {
            Task { await screenIfNeeded(c) }
        }
    }

    /// Resolve hosted logos for businesses we haven't looked up yet. One batched,
    /// best-effort call; a failure simply leaves those businesses on the monogram
    /// fallback. Only contractors with a website are sent (the rest can't resolve).
    @MainActor
    private func loadLogos(for batch: [Contractor]) async {
        let unknown = batch.filter { logoByID[$0.id] == nil && $0.website != nil }
        guard !unknown.isEmpty else { return }
        let found = await LogoService.fetch(for: unknown)
        guard !found.isEmpty else { return }
        logoByID.merge(found) { _, new in new }
    }

    /// Fetch each business's OWN uploaded photos and lead its strip with them.
    /// One batched query; most place_ids have no `business_profiles` row, so only
    /// the claimed few return. Owner photos are trusted verbatim (no screening) and
    /// prepended ahead of the Google/website shots, and the business is revealed
    /// immediately so its curated work shows on the first render.
    @MainActor
    private func loadOwnerPhotos(for batch: [Contractor]) async {
        let ids = batch.map(\.id).filter { ownerPhotosByID[$0] == nil }
        guard !ids.isEmpty else { return }
        let map = await BusinessService.uploadedPhotoURLs(placeIds: ids)
        guard !map.isEmpty else { return }
        for (id, urls) in map {
            ownerPhotosByID[id] = urls
            revealedIDs.insert(id)
            screenedByID[id] = withOwnerLead(id, screenedByID[id] ?? [])
        }
    }

    /// Prepend a business's owner-uploaded photos ahead of `list`, de-duped. The
    /// choke point every `screenedByID` write for a claimed business flows through,
    /// so screening/enrichment can re-order the Google photos without ever dropping
    /// the owner's curated ones from the lead.
    private func withOwnerLead(_ id: String, _ list: [String]) -> [String] {
        guard let owner = ownerPhotosByID[id], !owner.isEmpty else { return list }
        let have = Set(owner)
        return owner + list.filter { !have.contains($0) }
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
        ownerPhotosByID = [:]
        scannedCount = [:]
        revealedIDs = []
        needsEnrich = []
        nextPageToken = nil
        estimate = nil
        licenseByID = [:]
        logoByID = [:]
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
        let allowVehicles = allowsVehiclePhotos(effectiveSearchQuery)
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
            if ownerPhotosByID[c.id] != nil {
                // No Google work photos, but the business uploaded its own — show
                // those instead of dropping the claimed business.
                screenedByID[c.id] = withOwnerLead(c.id, [])
                revealedIDs.insert(c.id)
            } else {
                // Whole pool was non-work imagery → drop the business rather than
                // show a blank strip (mirrors the gallery).
                contractors.removeAll { $0.id == c.id }
            }
        } else {
            keptPhotos[c.id] = kept
            // Reveal once, ordered so query-matching photos (e.g. the kitchen) lead;
            // any owner-uploaded photos stay pinned ahead of them.
            screenedByID[c.id] = withOwnerLead(c.id, PhotoFilter.order(kept, query: orderQuery,
                                                   capPremises: stripMaxPremises))
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
        let allowVehicles = allowsVehiclePhotos(effectiveSearchQuery)
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
                screenedByID[id] = withOwnerLead(id, PhotoFilter.order(enriched, query: orderQuery,
                                                     capPremises: stripMaxPremises))
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

/// How far down the ranked list to eagerly screen at load so the similar-job
/// promotion is settled for the visible window before the user scrolls. A few
/// beyond `initialVisibleCount` so a match just below the fold can still be
/// pulled up. Screening below this stays lazy (per-row on reveal).
private let eagerScreenDepth = 8

/// Screening budget per row: scan `stripBatchScan` source photos at a time,
/// deeper into the pool only if early shots are rejected, keeping up to
/// `stripMaxKept` (a few spares beyond the three the mosaic shows, so the
/// query-first ordering has room to pick the best three — and the gallery
/// inherits them pre-screened).
private let stripBatchScan = 4
private let stripMaxKept = 10
/// At most one premises/storefront shot in a card's mosaic when the business also
/// has real work photos — otherwise a shop with few work shots fills the card with
/// repeated shopfront/signage tiles instead of the actual jobs.
private let stripMaxPremises = 1
/// Target number of work photos for the initial fill — a little over the three
/// the mosaic displays, so a rejected early shot doesn't leave a gap.
private let stripInitialFill = 4

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractorListRow
// One contractor (Figma 908:2558): a name + "Get quote" header row; then (12pt
// below) a left-aligned metadata line — a quiet single-star rating, review link,
// and the "Licensed" / "Did similar job" cues as one inline dot-separated text
// run (no pills); then a fixed 234pt photo mosaic —
// one large left tile and two stacked right tiles — showing up to 3 of the
// business's work photos, ordered so the ones most related to the user's request
// lead. The price estimate lives in the screen header (one per job), not per
// business. Tapping a photo (or the name) opens the gallery for this contractor.
// ─────────────────────────────────────────────────────────────────────────────

private struct ContractorListRow: View {
    let contractor: Contractor
    /// Screened work photos, or nil while screening is still in flight (the mosaic
    /// then shows gray placeholders so the row's text isn't held back).
    let photos: [String]?
    /// The active CSLB licence number, or nil when none is on file — which
    /// includes every business outside California, so its absence says nothing
    /// and must never render as "Unlicensed". Non-nil ⇒ show the "Licensed
    /// #<no>" cue; the number is public record (verifiable on CSLB) and the
    /// concrete trust signal, versus a bare "Licensed" word.
    let licenseNo: String?
    private var isLicensed: Bool { licenseNo != nil }
    /// True when this business has a screened work photo matching the request —
    /// draws the "Did similar job" proof-of-work tag. Absence draws no tag (the
    /// signal is one-directional, like the licence badge).
    let didSimilarJob: Bool
    /// A customer review naming the searched job, or nil — shown as a quoted
    /// one-liner under the metadata so a match reads in the customer's own words.
    let matchingReview: String?
    /// Hosted logo URL, or nil to draw a name monogram (see `ContractorLogoView`).
    let logoURL: URL?
    /// Opens the gallery on this contractor at the given photo index (0 for the
    /// name tap; the mosaic passes the exact tile tapped).
    let onOpen: (Int) -> Void
    let onReviews: () -> Void
    /// Fired by the row's "Get quote" capsule — requests a quote from this business.
    let onQuote: () -> Void
    /// Fired by the row's "Call" capsule — the parent shows the shared reminder
    /// pop-up, then dials. (Not dialed here, so the mention-Brightglow nudge shows
    /// from the list exactly as it does from the gallery.)
    let onCall: () -> Void

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
            // Figma 793:1779: 12pt between the name/CTA row and the metadata row.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: { onOpen(0) }) {
                        HStack(spacing: 8) {
                            ContractorLogoView(name: contractor.name, url: logoURL)
                            Text(contractor.name)
                                .font(.h3)                  // Lato 700 / 18
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Two icon buttons (Figma 1049:4441): 44x32 pills, 8pt apart.
                    // Call (secondary/dark) whenever there's a phone; Get quote
                    // (primary/blue, chat glyph) whenever we can DELIVER a quote —
                    // a phone (it now sends as a P2P text) OR an email. That's
                    // effectively every business, so the quote CTA is back on the
                    // row rather than gated to email-only businesses.
                    HStack(spacing: 8) {
                        if contractor.phone != nil {
                            Button(action: onCall) {
                                // Exact phone icon from Figma (1049:4441), white
                                // template on the pill.
                                Image("PhoneIcon")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 32)
                                    .background {
                                        ZStack {
                                            Rectangle().fill(.ultraThinMaterial)
                                            AppColors.btnSecondary
                                        }
                                    }
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        if contractor.phone != nil || contractor.contactEmail != nil {
                            Button(action: onQuote) {
                                // Chat glyph from Figma (1049:4441) — "message this
                                // business for a quote", white template on the blue pill.
                                Image("ic_chat")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 32)
                                    .background(AppColors.btnPrimary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 32)

                // Figma 908:2558: metadata is ONE quiet inline line — a small gold
                // star, then "4.7 • 31 reviews • Licensed • Did similar job", all
                // bodySmall at 50% white. No pills. Only "31 reviews" is underlined
                // (the tappable link to the Google reviews). "Licensed" appears only
                // against a verified ACTIVE state licence (its absence says nothing);
                // "Did similar job" only when a screened work photo matches the request.
                HStack(alignment: .center, spacing: 8) {
                    if contractor.reviewCount > 0 {
                        Image(systemName: "star.fill")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundStyle(AppColors.starFilled)
                    }
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
                        if isLicensed {
                            Text(contractor.reviewCount > 0 ? " • Licensed" : "Licensed")
                        }
                        if didSimilarJob {
                            Text(contractor.reviewCount > 0 || isLicensed
                                 ? " • Did similar job" : "Did similar job")
                        }
                    }
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                    Spacer(minLength: 0)
                }

                // The customer's own words about this job — the "why" behind a
                // review-driven match. One quiet quoted line; tapping opens the
                // full reviews, same as the "N reviews" link.
                if let review = matchingReview {
                    Button(action: onReviews) {
                        Text("“\(review)”")
                            .font(.bodySmall)
                            .italic()
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

/// Rounds to two significant figures so the displayed price reads as an
/// estimate, not a false-precision quote: 1,512 → 1,500, 873 → 870, 433 → 430.
/// The engine's cents are for math; the header should never imply that much
/// certainty.
private func roundSig2(_ v: Int) -> Int {
    guard v >= 100 else { return v }
    let magnitude = Int(pow(10.0, floor(log10(Double(v))) - 1))
    return Int((Double(v) / Double(magnitude)).rounded()) * magnitude
}

/// A business's logo when one was resolved (LogoService), otherwise a colored
/// name monogram — so every row has a stable, recognizable mark and there's
/// never a blank slot. Hosted logos render on a white chip so dark/transparent
/// marks stay visible against the app's dark background.
private struct ContractorLogoView: View {
    let name: String
    let url: URL?
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        // Fill the whole tile edge-to-edge (no inset chip) so the
                        // mark reads as a solid thumbnail. On a white backing so
                        // dark/transparent logos still show against the dark UI.
                        image.resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .background(Color.white)
                            .clipped()
                    } else {
                        // Loading or failed → monogram (no spinner flash).
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var monogram: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(bgColor)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    /// First letters of the first two words, e.g. "Bay Area Plumbing" → "BA".
    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init)
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? String(name.prefix(1)).uppercased() : joined
    }

    /// Deterministic hue from the name so a business keeps the same color across
    /// launches (djb2 hash → hue).
    private var bgColor: Color {
        var hash = 5381
        for scalar in name.unicodeScalars { hash = (hash &* 33) &+ Int(scalar.value) }
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.65)
    }
}
