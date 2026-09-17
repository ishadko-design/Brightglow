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

/// Navigation payload for a multi-contractor quote request (prototype).
/// `Contractor` isn't Hashable, so the array rides inside this wrapper for
/// `navigationDestination(item:)` — keyed on the UUID alone.
private struct MultiQuoteRequest: Identifiable, Hashable {
    let id = UUID()
    let contractors: [Contractor]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

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
    /// The customer's resolved search city ("Daly City"), threaded to the
    /// quote-request screen so the texted lead is tagged with the JOB's city
    /// (not the business's). nil when no location was resolved.
    var userCity: String? = nil
    /// Photos the user attached before arriving here (camera capture + drawing,
    /// or the search bar's own picker) — carried to the quote-request screen.
    var attachedImages: [UIImage] = []
    /// Cost-relevant attributes extracted from the captured photo (size,
    /// capacity, material — e.g. "40 gallon, tankless"), if any. Narrows the
    /// price estimate only — never used for the business search.
    var photoDetails: String? = nil
    /// A ready-to-show, human-readable description of the captured photo's subject
    /// ("Large two-panel sliding patio door"), from the vision classifier. Shown
    /// as a "From your photo" banner above the matches so the user sees what we
    /// understood — the ChatGPT-style diagnosis moment. Empty when the request
    /// carried no photo (typed search, grid-card tap).
    var photoDescription: String = ""
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
         userCity: String? = nil,
         attachedImages: [UIImage] = [],
         photoDetails: String? = nil,
         photoDescription: String = "",
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
        self.userCity = userCity
        self.attachedImages = attachedImages
        self.photoDetails = photoDetails
        self.photoDescription = photoDescription
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
    /// How small the pricing engine sized this job against the trade's tiers.
    /// `.belowFloor`/`.smallBand` both activate the small-job path (handyman
    /// pool widening + the size-fit score factor); the distinction is kept for
    /// analytics. `.standard` keeps today's behavior throughout.
    @State private var jobSize: JobSize = .standard
    @State private var resolvedCoord: CLLocationCoordinate2D? = nil
    @State private var isLoading   = false
    @State private var estimate: PriceTier? = nil
    /// True while the (web-grounded) estimate is still being fetched — drives the
    /// subtle "Estimating price…" placeholder so the header isn't blank during the
    /// few seconds the search takes.
    @State private var estimating = false

    /// The business whose "Get quote" was tapped — drives the quote screen.
    /// Figma 765:13844 moved the CTA from a floating bar into each row, so the
    /// request now targets that specific business rather than the top-ranked one.
    /// Held by id (not the value) because `navigationDestination(item:)` wants a
    /// Hashable, and `Contractor` isn't one.
    @State private var quoteContractorID: String? = nil
    // ── Multi-select prototype ──────────────────────────────────────────
    // In-memory only: the selection dies with this screen — nothing is
    // written to UserDefaults, files, or the backend.
    @State private var isSelectMode = false
    @State private var selectedIDs: Set<String> = []
    /// Retreating-footer visibility: the footer slides away while the user
    /// scrolls down through results and returns when they scroll back up.
    @State private var footerVisible = true
    /// Drives the multi-contractor quote screen (prototype).
    @State private var multiQuote: MultiQuoteRequest? = nil
    /// Cap on simultaneous selections (prototype).
    private let maxSelection = 5
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
    /// Contractors whose list-strip photo order is frozen for this session. The
    /// first ordering a row paints with is the one it keeps: late-arriving
    /// refinements (rich vision tags, website portfolio photos) still update the
    /// kept pool, the relevance score, and the cached/shared verdicts for future
    /// visits — but they must not reshuffle photos the user is already looking at.
    @State private var stripFrozenIDs: Set<String> = []
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
    /// Businesses whose OWN WEBSITE photos we've already fetched this session (once
    /// per business — the `business-photos` function caches across users). Google
    /// Places caps at 10 photos, mostly storefront; a contractor's site portfolio is
    /// the real "similar job" content, so we fold it into the row here too — not just
    /// in the gallery.
    @State private var websiteFetched: Set<String> = []
    /// Active contractor licences (CSLB), by contractor id. Absence means
    /// "unknown" — CSLB is California-only — never "unlicensed", so a missing
    /// entry shows no badge rather than a negative one.
    @State private var licenseByID: [String: LicenseService.License] = [:]

    /// Hosted logo URLs by contractor id, filled best-effort after load. A
    /// business not present here draws a name monogram (see [[LogoService]]).
    @State private var logoByID: [String: URL] = [:]
    /// How many of the (relevance-ranked) contractors are shown. Starts at the
    /// five best-matching; scrolling reveals five more at a time.
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

    /// Vehicle label sent to the business on an Auto & moto quote, so a shop
    /// that services both cars and bikes knows which this is. Empty for home.
    private var quoteVehicleNote: String {
        guard autoCategory != nil else { return "" }
        return vehicle == .moto ? "Motorcycle" : "Car"
    }

    /// Whether vehicle photos count as work photos for this search. Same veto as
    /// `autoCategory`, and needed separately because `isAutoService` also matches
    /// on the query text — "refrigerator repair service" hits the Repair
    /// keywords, which would keep car photos on an appliance search.
    private func allowsVehiclePhotos(_ query: String) -> Bool {
        guard clarifyVertical != "home" else { return false }
        return isAutoService(category: category, searchQuery: query)
    }

    /// Query actually sent to Places — the chat's refined `search_terms` when
    /// present, else the user's typed words, else (only for a bare category
    /// grid-card tap) the category's generic Places query.
    ///
    /// Auto used to ALWAYS collapse to the generic per-category query
    /// (`auto.query(for:)`), discarding the specific request: "car wrap" was
    /// searched as "auto body and paint shop", which returns collision/paint
    /// shops with no wrap work — so no wrap photos surfaced, the ranker led with
    /// storefront/building shots, and pricing lost the job. The refined terms the
    /// chat already produces ("full vinyl wrap installer SUV") find the actual
    /// wrap specialists, so use them. A grid-card tap carries no specific request
    /// and still falls back to the generic query (honoring the Moto toggle).
    private var effectiveSearchQuery: String {
        let override = businessSearchOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let auto = autoCategory else {
            return override.isEmpty ? searchQuery : override
        }
        let specific = override.isEmpty ? typedQuery : override
        guard !specific.isEmpty else { return auto.query(for: vehicle) }
        // Keep the Moto toggle meaningful for a specific request: prefix it so
        // Google reads it as a bike job, unless the phrase already names one.
        let lower = specific.lowercased()
        if vehicle == .moto, !lower.contains("motorcycle"), !lower.contains("moto") {
            return "motorcycle \(specific)"
        }
        return specific
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

    /// What the user actually typed, if anything.
    ///
    /// An auto GRID-CARD tap carries a synthetic Places query ("tire shop") in
    /// `searchQuery`; that's routing input, not the user's words. But a
    /// typed/clarified auto request ("I need to replace tires on the motorcycle")
    /// puts the user's ACTUAL words there — those SHOULD carry through. So
    /// suppress ONLY the synthetic query, not every auto category (the same
    /// distinction `pricingDescription` makes). Home is untouched.
    private var typedQuery: String {
        let typed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let auto = autoCategory else { return typed }
        let synthetic = [auto.searchQuery.lowercased(), auto.motoSearchQuery.lowercased()]
        return synthetic.contains(typed.lowercased()) ? "" : typed
    }

    /// The vehicle type to segregate work photos by (Auto ⇄ Moto). Only set for an
    /// auto/moto search; nil for home (and any non-vehicle search), where it filters
    /// nothing. A Moto view must show ONLY motorcycle photos — no cars, even from a
    /// shop that services both — so this is passed into every `PhotoFilter.order`.
    private var photoVehicle: VehicleFilter? {
        allowsVehiclePhotos(effectiveSearchQuery) ? vehicle : nil
    }

    /// Term source for photo ordering — the chat's `photo_terms` when present (a
    /// direct description of a matching work photo), else the live query, else
    /// the category, so a plain category browse still leads with its best photos.
    private var orderQuery: String {
        let terms = photoMatchTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { return terms }
        return effectiveSearchQuery.isEmpty ? category : effectiveSearchQuery
    }

    /// Query used solely for the similar-job ranking signal — real user intent
    /// only: the chat's `photo_terms`, else a chat-refined search (home only, like
    /// `effectiveSearchQuery`), else what the user actually typed. Deliberately
    /// omits the bare-category / synthetic auto-category fallback that `orderQuery`
    /// uses, so simply opening a category with no input contributes no job signal
    /// (empty → every match strength scores 0).
    private var matchQuery: String {
        let terms = photoMatchTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { return terms }
        let override = businessSearchOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if autoCategory == nil, !override.isEmpty { return override }
        return typedQuery
    }

    /// The rows actually rendered — ranked by composite relevance, strongest
    /// first. Only the five best show initially; scrolling reveals five more at a
    /// time (`showMore`), so the user meets the strongest candidates first and
    /// capacity (photo screening, website portfolios) is spent only on rows the
    /// user actually reaches. Scores refine as photo screening completes — a
    /// photo-confirmed match climbs without any re-fetch.
    private var visibleContractors: [Contractor] {
        let total = contractors.count
        let scored = contractors.enumerated()
            .map { (offset: $0.offset, contractor: $0.element,
                    score: relevanceScore($0.element, upstreamIndex: $0.offset, upstreamCount: total)) }
        // Single score sort — trade match, size fit, and upstream quality
        // compete in one number, so a 5-star plumber whose reviews name the job
        // can still outrank a mediocre handyman on a small plumbing job.
        // Fairness means the same factors for every business on every job: no
        // tiers, no pre-decided winners.
        let ranked = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.offset < $1.offset
        }
        return Array(ranked.map(\.contractor).prefix(visibleLimit))
    }

    /// Licensed-work check for this job, driven by the OTA config. Electrical
    /// is always licensed-only (life safety). Plumbing/HVAC stay licensed-only
    /// when the job description names licensed-level work (gas, furnace,
    /// refrigerant…); without those signals a small job is handyman-appropriate.
    private var isLicensedSpecialty: Bool {
        let trade = Category(rawValue: category)
            ?? Category.matching(query: effectiveSearchQuery).first
        guard let trade else { return false }
        let rule = RankingConfigStore.current.licensed[trade.rawValue.lowercased()]
        if rule?.always == true { return true }
        guard let signals = rule?.signals, !signals.isEmpty else { return false }
        return jobMentions(signals)
    }

    /// Whole-phrase match of any signal against the job description — " gas "
    /// won't match "gasket".
    private func jobMentions(_ signals: [String]) -> Bool {
        let text = " " + pricingDescription.lowercased() + " "
        return signals.contains { text.contains(" " + $0.lowercased() + " ") }
    }

    /// True when this search takes the small-job path: the pricing engine sized
    /// the job at or below the trade's smallest tier and the trade isn't
    /// licensed for this job. Drives the handyman supplement in `load()` and
    /// the size-fit factor in `relevanceScore` — one predicate so the candidate
    /// pool and the ordering never disagree about who the job is for.
    private var smallJobActive: Bool {
        RankingConfigStore.current.smallJob.enabled && jobSize != .standard && !isLicensedSpecialty
    }

    /// The job's trade as a Category, when the search resolved to one.
    private var jobCategory: Category? { Category(rawValue: category) }

    /// Composite relevance score — the single number that decides which five
    /// lead. Job-specific proof first, upstream quality order as the base: a
    /// review naming the searched work and a screened work photo of it outrank
    /// every free-signal heuristic, because they're the only signals that say
    /// THIS business does THIS job. The upstream Places order (proximity,
    /// rating quality, small-operator boost — see PlacesService.rankByRelevance)
    /// carries the rest, so a thin signal set still sorts sensibly. The
    /// size-fit factor scores whether the business is the right size for this
    /// job's price — a handyman for a small job — as one competing factor, not
    /// a pre-decided tier. All four weights are OTA-tunable (`ranking_config`).
    private func relevanceScore(_ c: Contractor, upstreamIndex: Int, upstreamCount: Int) -> Double {
        let w = RankingConfigStore.current.weights
        let reviews = c.reviews.map(\.text)
        let review = PhotoFilter.reviewMatchStrength(reviews, query: matchQuery)
        let photo = PhotoFilter.photoMatchStrength(keptPhotos[c.id] ?? [], query: matchQuery, category: category)
        let upstream = upstreamCount > 1 ? 1 - Double(upstreamIndex) / Double(upstreamCount - 1) : 1
        let sizeFit = smallJobActive && takesSmallJobs(c, category: jobCategory) ? 1.0 : 0.0
        let score = w.reviewMatch * review + w.photoMatch * photo
            + w.sizeFit * sizeFit + w.upstream * upstream
        return min(score, 1)
    }

    /// Single source of truth for the "Takes small jobs" cue: true when the
    /// business's own profile or its reviewers say it takes on small work.
    /// One-directional — absence draws no cue, never a negative badge.
    ///
    /// Trade-aware via `category`: repair language in the job's own trade
    /// ("roof repair", "fixed my roof") counts as a strong claim, and a review
    /// profile dominated by install/replacement work ("new roof", "full
    /// replacement") with no repair mention vetoes the cue — across every
    /// trade, repair businesses take small jobs and install businesses don't.
    /// The veto only ever suppresses the positive cue; it never renders a
    /// negative badge.
    private func takesSmallJobs(_ c: Contractor, category cat: Category?) -> Bool {
        // A handyman IS the small-jobs business model — no review-mining needed.
        if c.placeTypes.contains("handyman") { return true }
        if c.name.localizedCaseInsensitiveContains("handyman") { return true }
        let texts = c.reviews.map(\.text).map { " \($0.lowercased()) " }
        guard !texts.isEmpty else { return false }
        // Explicit "no job too small"-style claims: one hit is enough. The
        // job's own trade in repair language joins the strong list — a roofer
        // reviewers say "repaired my roof" is exactly the missing middle.
        var strong = ["no job too small", "no job is too small", "small jobs welcome",
                      "any size job", "any size project"]
        if let cat = cat { strong += tradeRepairPhrases(for: cat) }
        if strong.contains(where: { s in texts.contains(where: { $0.contains(s) }) }) { return true }
        // Explicit refusals veto everything — never claim it when a reviewer
        // says the business turned small work away.
        let negative = ["too small", "wouldn't take", "would not take",
                        "only large", "only big", "large jobs only",
                        "won't do small", "wouldn't do small"]
        if negative.contains(where: { s in texts.contains(where: { $0.contains(s) }) }) { return false }
        // Install/replacement-dominated profile with no repair mention: this
        // business does big jobs, not small ones. Conservative by design —
        // three independent install mentions, zero repair mentions.
        if installDominated(texts) && !repairMentioned(texts) { return false }
        // Weaker small-work mentions: need two independent hits.
        let positive = ["small job", "small jobs", "minor repair", "quick fix",
                        "tiny job", "small repair", "little job"]
        let hits = texts.reduce(0) { total, text in total + positive.filter { p in text.contains(p) }.count }
        return hits >= 2
    }

    /// Repair-language phrases for the job's own trade — one hit is a strong
    /// "takes small jobs" claim. The general form of the flashing lesson: the
    /// business reviewers describe doing *repairs* takes small work.
    private func tradeRepairPhrases(for cat: Category) -> [String] {
        switch cat {
        case .roofing:      return ["roof repair", "roof repaired", "repaired my roof", "repaired our roof",
                                    "fixed my roof", "fixed our roof", "small roof job", "roof leak fixed"]
        case .plumbing:     return ["plumbing repair", "fixed my leak", "fixed our leak", "leak fixed",
                                    "small plumbing job", "repaired my faucet", "fixed my toilet"]
        case .electrical:   return ["electrical repair", "small electrical job", "fixed my outlet",
                                    "outlet fixed", "fixed our wiring"]
        case .hvac:         return ["hvac repair", "furnace repair", "ac repair", "fixed my ac",
                                    "fixed our furnace", "small hvac job"]
        case .appliances:   return ["appliance repair", "fixed my fridge", "fixed my washer",
                                    "fixed our dryer", "small appliance job"]
        case .carpentry:    return ["carpentry repair", "small carpentry job", "fixed my deck",
                                    "trim repair", "fixed our fence"]
        case .windowsDoors: return ["window repair", "door repair", "fixed my window",
                                    "small window job", "repaired my door"]
        case .flooring:     return ["floor repair", "fixed my floor", "small floor job",
                                    "repaired my floor"]
        case .painting, .landscaping, .pestControl, .generalContractor: return []
        }
    }

    /// True when reviewers describe install/replacement work at least three
    /// times — the profile of a business that does big jobs.
    private func installDominated(_ texts: [String]) -> Bool {
        let install = ["new roof", "roof replacement", "replaced my roof", "replaced our roof",
                       "full replacement", "new installation", "installed a new", "full remodel",
                       "new construction"]
        let hits = texts.reduce(0) { total, text in total + install.filter { p in text.contains(p) }.count }
        return hits >= 3
    }

    /// True when any review mentions repair work at all.
    private func repairMentioned(_ texts: [String]) -> Bool {
        ["repair", "repaired", "fixed"].contains(where: { s in texts.contains(where: { $0.contains(s) }) })
    }

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
            // Retreating multi-select footer (prototype) — floats above the
            // list, same fading-gradient treatment as the gallery's button bar.
            .overlay(alignment: .bottom) {
                selectFooter(bottomInset: proxy.safeAreaInsets.bottom)
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
                clarifyTranscript: clarifyTranscript,
                userCity: userCity,
                vehicleNote: quoteVehicleNote
            )
        }
        .navigationDestination(item: $quoteContractorID) { id in
            // Same consent/review step the gallery uses, aimed at the business
            // whose row CTA was tapped.
            QuoteRequestScreen(
                contractor: contractors.first { $0.id == id },
                initialImages: attachedImages,
                vehicleNote: quoteVehicleNote,
                clarifyTranscript: clarifyTranscript,
                userCity: userCity
            )
        }
        .navigationDestination(item: $multiQuote) { req in
            // Multi-select prototype: the send screen lists every selected
            // business and sends the request to each in turn.
            QuoteRequestScreen(
                contractors: req.contractors,
                initialImages: attachedImages,
                vehicleNote: quoteVehicleNote,
                clarifyTranscript: clarifyTranscript,
                userCity: userCity
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
        // Meter the call toward the business's free allowance (fire-and-forget).
        LeadBridgeService.recordCall(placeId: contractor.id, businessName: contractor.name,
                                     website: contractor.website, city: contractor.city,
                                     contractorEmail: contractor.contactEmail ?? "hello@brightglow.co",
                                     contractorPhone: phone)
        AnalyticsService.track("call_tapped", ["place_id": contractor.id, "surface": "list"])
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
                            takesSmallJobs: takesSmallJobs(contractor, category: jobCategory),
                            // The customer's own words about this job — shown as
                            // the "why" when a review names the searched work.
                            matchingReview: matchingReview(contractor),
                            logoURL: logoByID[contractor.id],
                            onOpen: { photoIndex in open(contractor, photoIndex: photoIndex) },
                            onReviews: { openReviews(for: contractor) },
                            onQuote: { quoteContractorID = contractor.id },
                            onCall: { callContractor = contractor },
                            onPhotoUnavailable: { url in dropUnusablePhoto(url, from: contractor.id) },
                            onNoUsablePhotos: { dropPhotolessBusiness(contractor.id) },
                            // Multi-select prototype: the logo slot becomes a checkbox.
                            selectionMode: isSelectMode,
                            isSelected: selectedIDs.contains(contractor.id),
                            onToggleSelect: { toggleSelect(contractor) }
                        )
                        .id(contractor.id)
                        // Strictly lazy: reveal (and screen) a row's photos only when
                        // it genuinely scrolls into view — not LazyVStack's render buffer.
                        .onScrollVisibilityChange(threshold: 0.05) { visible in
                            guard visible, !revealedIDs.contains(contractor.id) else { return }
                            revealedIDs.insert(contractor.id)
                            Task { await screenIfNeeded(contractor) }
                            Task { await enrichIfNeeded(contractor) }
                            // Pull in the business's own website portfolio (free, cached).
                            Task { await mergeWebsitePhotos(for: contractor) }
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
            // Pull to refresh — re-runs the search and re-screens, so photos that
            // failed to load (or a business that came back thin) get another pass.
            // A fresh screening re-fetches images the cache never stored (a failed
            // fetch isn't cached), so a transient miss recovers on the next pull.
            .refreshable { await reload() }
            // Retreating footer (prototype): slides away while the user scrolls
            // down through results (revealing more content) and returns when
            // they scroll back up.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { old, new in
                let dy = new - old
                guard abs(dy) > 2 else { return }
                footerVisible = dy < 0 || new <= 0
            }
        }
    }

    // ── Multi-select footer (prototype) ─────────────────────────────────────
    // The pill floats over the shared blurred footer backdrop: a tall
    // black→transparent scrim (up past the viewport, so the fade never reads
    // as a floating band), layer-blurred like the header — no backdrop blur.
    // Pill: 32pt, frosted secondary (live background blur under the white-at-20%
    // tint, Figma "Background blur"), Lato 14 Bold (.h4). "Request quotes" turns
    // solid primary blue once something is selected.
    // The backdrop is visual-only (never intercepts touches); only the pills
    // are tappable, so list rows beside them stay reachable.
    private func selectFooter(bottomInset: CGFloat) -> some View {
        let shown = isSelectMode || footerVisible
        // Full-height scrim: must clear the screen entirely when retreating.
        let fadeH: CGFloat = 160
        let extendH: CGFloat = 800
        return ZStack(alignment: .bottom) {
            BlurredFooterBackground(height: fadeH, topExtend: extendH, bottomInset: bottomInset)
            HStack(spacing: 8) {
                if isSelectMode {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelectMode = false
                            selectedIDs = []
                        }
                    }) {
                        Text("Cancel")
                            .font(.h4)
                            .foregroundStyle(.white)
                            .frame(height: 32)
                            .padding(.horizontal, 20)
                            .background { FrostedPillBackground() }
                    }
                    .buttonStyle(.plain)
                    Button(action: startMultiQuote) {
                        Text("Request quotes")
                            .font(.h4)
                            .foregroundStyle(.white)
                            .frame(height: 32)
                            .padding(.horizontal, 20)
                            .background {
                                if selectedIDs.isEmpty {
                                    FrostedPillBackground()
                                } else {
                                    Capsule().fill(AppColors.btnPrimary)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedIDs.isEmpty)
                    // The counter is plain text, not part of the button.
                    Text("(\(selectedIDs.count))")
                        .font(.h4)
                        .foregroundStyle(.white)
                } else {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { isSelectMode = true }
                    }) {
                        Text("Select multiple")
                            .font(.h4)
                            .foregroundStyle(.white)
                            .frame(height: 32)
                            .padding(.horizontal, 20)
                            .background { FrostedPillBackground() }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 16 + bottomInset)
        }
        .frame(maxWidth: .infinity)
        .offset(y: shown ? 0 : extendH + fadeH + bottomInset)
        .opacity(shown ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: shown)
        .allowsHitTesting(shown)
    }

    /// Toggles a contractor's selection, capped at `maxSelection` (prototype —
    /// further taps at the cap are ignored).
    private func toggleSelect(_ c: Contractor) {
        if selectedIDs.contains(c.id) {
            selectedIDs.remove(c.id)
        } else if selectedIDs.count < maxSelection {
            selectedIDs.insert(c.id)
        }
    }

    /// Heads to the send screen with the selected businesses (prototype).
    private func startMultiQuote() {
        let picked = contractors.filter { selectedIDs.contains($0.id) }
        guard !picked.isEmpty else { return }
        multiQuote = MultiQuoteRequest(contractors: picked)
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
        // A concise RANGE reads clearer than a lone "~$5.4k", which users found
        // ambiguous on its own (2026-08-09) — a single number implies a precision
        // the estimate doesn't have. Anchor on the rounded low–high; the info
        // button still opens the full typical + drivers.
        let range = "$\(money(roundSig2(tier.min)))–$\(money(roundSig2(tier.max)))"
        // Labor-only figures MUST carry the qualifier — the same number unlabelled
        // would read as the whole job (pilot, 2026-07-16).
        return tier.laborOnly ? "Typically \(range) labor only" : "Typically \(range)"
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
                } else if estimating {
                    EstimatingLabel()
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(alignment: .top) { BlurredHeaderBackground(style: .dark) }
    }

    private func statusView(spinner: Bool, text: String) -> some View {
        VStack(spacing: 16) {
            if spinner { ThinkingOrb(size: 52, color: .white) }
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

    /// Reveal the next five already fetched; if the limit has caught up with the
    /// fetched set, pull the next Places page instead. Photos still load lazily
    /// per row, so revealing rows costs nothing until the user scrolls to them.
    @MainActor
    private func showMore() async {
        guard !isLoadingMore else { return }

        if contractors.count > visibleLimit {
            withAnimation(.easeInOut(duration: 0.2)) { visibleLimit += 5 }
            return
        }

        guard let token = nextPageToken, let coord = resolvedCoord else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let page = await ContractorLoader.fetchLivePage(
            category: category, searchQuery: effectiveSearchQuery, near: coord, pageToken: token,
            isAuto: allowsVehiclePhotos(effectiveSearchQuery))
        let existing = Set(contractors.map(\.id))
        let fresh = page.contractors.filter { !existing.contains($0.id) }
        nextPageToken = page.nextPageToken
        guard !fresh.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            contractors.append(contentsOf: fresh)
            visibleLimit += 5
        }
        await loadLicenses(for: fresh)
    }

    // ── Data loading + progressive photo screening ────────────────────────────

    /// How small a job is relative to its trade's price tiers.
    private enum JobSize {
        /// A normal job — today's behavior throughout.
        case standard
        /// Inside the trade's smallest tier band (e.g. a $256 trim job in
        /// carpentry's $150–$400 "Small repair"): handyman-appropriate, so the
        /// pool widens with handymen and the size-fit factor boosts them —
        /// trade shops stay in the list as fallback.
        case smallBand
        /// Below the trade's smallest tier floor: no trade shop will mobilize,
        /// so handymen get the same pool widening + size-fit boost; trade
        /// shops remain only as fallback.
        case belowFloor
    }

    /// Sizes the job against the trade's price tiers. `.belowFloor` (typical
    /// under the smallest tier's floor) and `.smallBand` (typical inside the
    /// smallest tier, e.g. $256 trim in carpentry's $150–$400 "Small repair")
    /// both activate the small-job path — handyman pool widening in `load()`
    /// plus the size-fit factor in `relevanceScore` — for non-licensed trades.
    /// The search itself is always the trade query; ranking decides who leads.
    /// Fails open — no estimate, no resolvable trade, an unpriceable category, or
    /// an auto job keeps today's trade search. The estimate uses the header's
    /// exact inputs, so the clarify chat's prefetch usually serves it warm — no
    /// added latency.
    private func smallJobLevel(near coord: CLLocationCoordinate2D, isAuto: Bool) async -> JobSize {
        guard !isAuto, priceable else { return .standard }
        let trade = Category(rawValue: category)
            ?? Category.matching(query: effectiveSearchQuery).first
        guard let smallest = trade?.priceTiers.min(by: { $0.min < $1.min }) else { return .standard }
        guard let tier = await ContractorLoader.estimate(
            category: category, searchQuery: pricingDescription, near: coord,
            photoDetails: photoDetails, vehicle: nil, fast: false)
        else { return .standard }
        let typical = tier.typical ?? tier.min
        if typical < smallest.min { return .belowFloor }
        if typical <= smallest.max { return .smallBand }
        return .standard
    }

    @MainActor
    private func load() async {
        guard contractors.isEmpty else { return }
        isLoading = true

        let resolved = await ContractorLoader.resolveCoordinate(
            preset: presetCoordinate, location: location)

        var query = effectiveSearchQuery
        let isAuto = allowsVehiclePhotos(query)
        if let coord = resolved {
            // The estimate reuses the header's inputs, so the clarify chat's
            // prefetch usually serves it warm — no added latency. Fails open.
            // Refresh the OTA ranking config in the background — never blocks the
            // search; new weights apply to scoring live.
            Task { await RankingConfigStore.refresh() }
            jobSize = await smallJobLevel(near: coord, isAuto: isAuto)
            // The search is always the trade query — plumber jobs search
            // plumbers. Handyman preference is expressed in ranking (the
            // size-fit factor), never by rerouting the query.
            var page = await ContractorLoader.fetchLivePage(
                category: category, searchQuery: query, near: coord, isAuto: isAuto)
            // Small non-licensed job: widen the pool with handymen so the
            // size-fit factor has someone to score. Merged deduped, first page
            // only — pagination continues the trade query untouched.
            if smallJobActive {
                let extra = await ContractorLoader.fetchHandymanSupplement(
                    near: coord, count: RankingConfigStore.current.smallJob.supplementCount)
                let existing = Set(page.contractors.map(\.id))
                let fresh = extra.filter { !existing.contains($0.id) }
                if !fresh.isEmpty {
                    page = PlacesService.Page(contractors: page.contractors + fresh,
                                              nextPageToken: page.nextPageToken)
                }
            }
            // Small non-licensed job: also widen with "{trade} repair" pros —
            // the missing middle between full-trade contractors and generic
            // handymen. A roofer who does flashing fixes is found by
            // "roof repair", not by "roofing contractor". Merged deduped,
            // first page only — pagination continues the trade query untouched.
            if smallJobActive, let cat = jobCategory, let repairQ = cat.repairQuery {
                let extra = await ContractorLoader.fetchTradeRepairSupplement(
                    near: coord, count: RankingConfigStore.current.smallJob.supplementCount, repairQuery: repairQ)
                let existing = Set(page.contractors.map(\.id))
                let fresh = extra.filter { !existing.contains($0.id) }
                if !fresh.isEmpty {
                    page = PlacesService.Page(contractors: page.contractors + fresh,
                                              nextPageToken: page.nextPageToken)
                }
            }
            // Zero-result safeguard: a chat-refined query that finds nothing
            // falls back to the user's raw query, so narrowing the search can
            // never blank the results.
            let base = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if page.contractors.isEmpty, !base.isEmpty, base != query {
                query = base
                page = await ContractorLoader.fetchLivePage(
                    category: category, searchQuery: query, near: coord, isAuto: isAuto)
            }
            contractors = page.contractors
            nextPageToken = page.nextPageToken
            resolvedCoord = coord
            AnalyticsService.track("results_shown", [
                "category": category,
                "count": contractors.count,
                "is_auto": isAuto,
                "small_job_active": smallJobActive,
                // Per-business impressions for the list surface: the ids shown
                // (capped so the payload stays small). Tallied server-side.
                "place_ids": Array(contractors.prefix(25).map { $0.id }),
                // `names` runs parallel to `place_ids` so the dashboard can label
                // each business instead of showing a raw place_id.
                "names": Array(contractors.prefix(25).map { $0.name }),
            ])
            // Reuse verdicts from a previous launch so businesses screened before
            // show their photos immediately without re-downloading the pool.
            let allowVehicles = allowsVehiclePhotos(query)
            for c in contractors {
                guard let v = ScreeningStore.shared.get(c.id, allowVehicles: allowVehicles) else { continue }
                if !v.kept.isEmpty && PhotoFilter.hasWorkPhoto(v.kept) {
                    // Cached work photos → show them, ordered by the current query.
                    keptPhotos[c.id] = v.kept
                    setStripPhotos(c.id, PhotoFilter.order(v.kept, query: orderQuery, category: category,
                                                           capPremises: stripMaxPremises, vehicle: photoVehicle))
                    scannedCount[c.id] = v.scanned
                    // A verdict cached before rich tagging (or by an older build)
                    // orders only on generic labels — enrich it when its row shows.
                    if !v.enriched { needsEnrich.insert(c.id) }
                } else if v.scanned >= c.photos.count {
                    // Whole pool scanned but only premises/exterior (or nothing) →
                    // mark scanned so the drop below removes it; a storefront is not
                    // a work photo, so we never lead with it.
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
                    setStripPhotos(id, PhotoFilter.order(v.kept, query: orderQuery, category: category,
                                                         capPremises: stripMaxPremises, vehicle: photoVehicle))
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
            // So is a business with no Google photos but a website: its row reveal
            // pulls the site's portfolio, which drops the business itself when
            // nothing usable comes back. (Businesses WITH Google photos keep
            // today's behavior exactly.)
            contractors.removeAll { c in
                ownerPhotosByID[c.id] == nil
                    && (c.website == nil || !c.photos.isEmpty)
                    && (scannedCount[c.id] ?? 0) >= c.photos.count
                    && (screenedByID[c.id]?.isEmpty ?? true)
            }
            // Uncovered categories stay match-only — the price line shows the
            // "coming soon" state (with a real business count) instead. Auto &
            // moto is no longer among them; it passes its vehicle filter so a
            // bike isn't priced as a car.
            if !contractors.isEmpty && priceable {
                estimating = true
                let priceVehicle = allowVehicles ? vehicle : nil
                // Two-phase, so a number shows almost instantly.
                // Phase 1 — fast: the formula (plus any already-cached grounded
                // number), no web-search wait. Fills the header right away, unless
                // phase 2 already won the race on a warm cache.
                Task { @MainActor in
                    let fast = await ContractorLoader.estimate(
                        category: category, searchQuery: pricingDescription, near: coord,
                        photoDetails: photoDetails, vehicle: priceVehicle, fast: true)
                    if estimate == nil, let fast { estimate = fast }
                }
                // Phase 2 — full: the grounded (web-searched) number; replaces the
                // fast one when it arrives (kept if grounded comes back empty).
                Task { @MainActor in
                    let full = await ContractorLoader.estimate(
                        category: category, searchQuery: pricingDescription, near: coord,
                        photoDetails: photoDetails, vehicle: priceVehicle)
                    if let full { estimate = full }
                    estimating = false
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

    /// Fold the business's OWN WEBSITE photos into this row — the same free,
    /// zero-consent enrichment the gallery uses (`business-photos`), but on the LIST
    /// so the strip and the "did similar job" ranking see the contractor's actual
    /// portfolio, not just Google's 10 (mostly-storefront) photos. Screened the same
    /// way as Places (a site's hero is often a logo/van-wrap/storefront), added to
    /// the kept pool so ranking + the badge see them, and re-ordered query-first with
    /// any owner-uploaded photos kept on top. One call per business per session (the
    /// function caches across users). Lazy per revealed row, so cost stays bounded.
    @MainActor
    private func mergeWebsitePhotos(for contractor: Contractor) async {
        guard !websiteFetched.contains(contractor.id) else { return }
        websiteFetched.insert(contractor.id)
        let urls = await BusinessPhotoService.fetch(placeId: contractor.id, website: contractor.website)
        guard !urls.isEmpty, contractors.contains(where: { $0.id == contractor.id }) else {
            if urls.isEmpty { dropIfTrulyPhotoless(contractor) }
            return
        }

        let allowVehicles = allowsVehiclePhotos(effectiveSearchQuery)
        let screened = await PhotoFilter.screen(urls, allowVehicles: allowVehicles,
                                                limit: urls.count, scanLimit: urls.count)
        guard !screened.isEmpty, contractors.contains(where: { $0.id == contractor.id }) else {
            if screened.isEmpty { dropIfTrulyPhotoless(contractor) }
            return
        }

        // Add the site's work photos to the kept pool (so the relevance score
        // and the ordering see them), de-duped against what's already there.
        let existing = keptPhotos[contractor.id] ?? []
        let have = Set(existing.map(\.url))
        let fresh = screened.filter { !have.contains($0.url) }
        guard !fresh.isEmpty else { return }
        let merged = fresh + existing
        keptPhotos[contractor.id] = merged
        revealedIDs.insert(contractor.id)
        setStripPhotos(contractor.id, withOwnerLead(contractor.id,
            PhotoFilter.order(merged, query: orderQuery, category: category, capPremises: stripMaxPremises, vehicle: photoVehicle)))
        // Rich-tag the new photos so specific queries ("bumper", "hardwood") rank them.
        enrichInBackground(contractor.id, kept: merged,
                           scanned: scannedCount[contractor.id] ?? merged.count,
                           allowVehicles: allowVehicles)
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
            setStripPhotos(id, withOwnerLead(id, screenedByID[id] ?? []))
        }
    }

    /// Write-once strip assignment — the fix for photos reshuffling while scrolling.
    /// Before a row is revealed, ordering writes flow freely (cached verdict at
    /// load, then the reveal-time screen). Once the row has painted, the first
    /// post-reveal write wins and freezes the strip; later refinements (rich
    /// vision tags, website portfolio photos arriving late) are dropped for
    /// display purposes. Those refinements still update `keptPhotos` and the
    /// cached/shared verdicts at their own call sites, so the gallery, the
    /// relevance score, and future visits all benefit — only the visible strip
    /// stays put. Runs on MainActor with the other strip writes: no races.
    @MainActor
    private func setStripPhotos(_ id: String, _ urls: [String]) {
        if revealedIDs.contains(id) {
            guard !stripFrozenIDs.contains(id) else { return }
            stripFrozenIDs.insert(id)
        }
        screenedByID[id] = urls
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
        stripFrozenIDs = []
        needsEnrich = []
        websiteFetched = []
        nextPageToken = nil
        jobSize = .standard
        estimate = nil
        estimating = false
        licenseByID = [:]
        logoByID = [:]
        visibleLimit = initialVisibleCount
        await load()
    }

    /// A photo failed to load in the row — remove it from this business's display
    /// set and its cached verdict, so a stale/dead Places reference stops reserving
    /// a gray tile (and won't return next launch). Surgical: the business keeps its
    /// other photos.
    @MainActor
    private func dropUnusablePhoto(_ url: String, from id: String) {
        var changed = false
        if let i = screenedByID[id]?.firstIndex(of: url) { screenedByID[id]?.remove(at: i); changed = true }
        if let i = keptPhotos[id]?.firstIndex(where: { $0.url == url }) { keptPhotos[id]?.remove(at: i); changed = true }
        guard changed else { return }
        let allowVehicles = allowsVehiclePhotos(effectiveSearchQuery)
        ScreeningStore.shared.save(id, allowVehicles: allowVehicles,
                                   kept: keptPhotos[id] ?? [], scanned: scannedCount[id] ?? 0)
    }

    /// Delayed drop for businesses the mapping gate let through photo-less on the
    /// strength of their website: when the site yields no usable picture and
    /// there is no other photo source (no Google photos, no owner uploads), the
    /// business leaves the list — a listed contractor must show a real picture.
    /// No-op for businesses that have any other picture source or already left.
    @MainActor
    private func dropIfTrulyPhotoless(_ c: Contractor) {
        guard contractors.contains(where: { $0.id == c.id }),
              c.photos.isEmpty,
              ownerPhotosByID[c.id] == nil
        else { return }
        dropPhotolessBusiness(c.id)
    }

    /// Every photo for this business failed to load — drop it from the list so a
    /// listed contractor always shows a real picture. The verdict is reset to
    /// "unprimed" (not "no work photos"), so a later fresh screen — a relaunch or
    /// pull-to-refresh that re-fetches current Places photo names — can recover it
    /// rather than the failure being cached permanently.
    @MainActor
    private func dropPhotolessBusiness(_ id: String) {
        contractors.removeAll { $0.id == id }
        screenedByID[id] = nil
        keptPhotos[id] = nil
        scannedCount[id] = nil
        stripFrozenIDs.remove(id)
        revealedIDs.remove(id)
        let allowVehicles = allowsVehiclePhotos(effectiveSearchQuery)
        ScreeningStore.shared.save(id, allowVehicles: allowVehicles, kept: [], scanned: 0)
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
                setStripPhotos(c.id, withOwnerLead(c.id, []))
                revealedIDs.insert(c.id)
            } else if c.photos.isEmpty && c.website != nil {
                // No Google photos at all, but a website is on file: don't drop
                // yet — the website-photo merge fired on this same reveal may
                // still supply portfolio shots, and removes the business itself
                // when the site yields nothing usable.
            } else {
                // Whole pool was non-work imagery → drop the business rather than
                // show a blank strip (mirrors the gallery).
                contractors.removeAll { $0.id == c.id }
                stripFrozenIDs.remove(c.id)
                revealedIDs.remove(c.id)
            }
        } else {
            keptPhotos[c.id] = kept
            // Reveal once, ordered so query-matching photos (e.g. the kitchen) lead;
            // any owner-uploaded photos stay pinned ahead of them. This first
            // post-reveal write freezes the strip — later refinements must not
            // reshuffle it (see setStripPhotos).
            setStripPhotos(c.id, withOwnerLead(c.id, PhotoFilter.order(kept, query: orderQuery, category: category,
                                                   capPremises: stripMaxPremises, vehicle: photoVehicle)))
            // Then sharpen the kept pool (gallery, relevance, shared verdicts)
            // with rich vision tags in the background — the visible strip keeps
            // the order it already painted with.
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
                // Display write goes through the freeze: if the strip already
                // painted, the enriched order only reaches the stored verdicts.
                setStripPhotos(id, withOwnerLead(id, PhotoFilter.order(enriched, query: orderQuery, category: category,
                                                     capPremises: stripMaxPremises, vehicle: photoVehicle)))
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

/// How far down the ranked list to eagerly screen at load so the relevance
/// signals are settled for the visible window before the user scrolls.
/// Matches `initialVisibleCount` — screening below this stays lazy (per-row on
/// reveal), which is what keeps the 5-at-a-time paging cheap.
private let eagerScreenDepth = 5

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
// and the "Licensed" / "Takes small jobs" cues as one inline
// dot-separated text
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
    /// True when the business's profile or reviews say it takes small jobs —
    /// draws the "Takes small jobs" cue. One-directional: absence draws nothing,
    /// never a negative badge.
    let takesSmallJobs: Bool
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
    /// A specific photo URL failed to load — parent purges it from the cache so a
    /// stale/dead reference doesn't reserve a gray tile again next launch.
    let onPhotoUnavailable: (String) -> Void
    /// Every one of this business's photos failed to load — parent drops the
    /// business, enforcing "a listed contractor must show a real picture".
    let onNoUsablePhotos: () -> Void
    // ── Multi-select prototype ──────────────────────────────────────────
    /// When true the logo slot becomes a checkbox instead of the business logo.
    let selectionMode: Bool
    /// Whether this row is currently selected (prototype).
    let isSelected: Bool
    /// Toggles this row's selection (prototype).
    let onToggleSelect: () -> Void

    /// Photo URLs that failed to load, so their gray tiles are dropped and the
    /// mosaic re-lays-out around the survivors (or the row is removed if none).
    @State private var failed: Set<String> = []

    // Exact Figma values (793:1779).
    private let sideInset: CGFloat = 16      // content left/right margin
    private let mosaicHeight: CGFloat = 234  // fixed height of the photo block
    private let mosaicGap: CGFloat = 8       // gap between tiles (both axes)
    private let tileRadius: CGFloat = 16     // per-tile corner radius
    /// Up to this many of the (query-ordered) work photos appear in the mosaic —
    /// the three most related to the user's request.
    private let maxTiles = 3

    /// Multi-select checkbox (prototype): replaces the logo slot. The circle is
    /// 26pt but the tappable area is the full 44×44, so it's easy to hit.
    private var selectCheckbox: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(AppColors.btnPrimary)
                    .frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.45), lineWidth: 2)
                    .frame(width: 26, height: 26)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    var body: some View {
        // Header block (8pt above the photo mosaic).
        VStack(alignment: .leading, spacing: 8) {
            // ── Name + quote CTA / rating ─────────────────────────────────────
            // Figma 793:1779: 12pt between the name/CTA row and the metadata row.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: { selectionMode ? onToggleSelect() : onOpen(0) }) {
                        HStack(spacing: 8) {
                            if selectionMode {
                                selectCheckbox
                            } else {
                                ContractorLogoView(name: contractor.name, url: logoURL)
                            }
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
                                    .frame(width: 24, height: 24)
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
                                // Its own asset (not the shared header ic_chat) so the
                                // CTA can carry Figma's exact 24pt icon size without
                                // resizing the larger MainScreen header bubble.
                                Image("ic_message")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
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
                // star, then "4.7 • 31 reviews • Licensed • Takes small jobs", all
                // bodySmall at 50% white. No pills. Only "31 reviews" is underlined
                // (the tappable link to the Google reviews). "Licensed" appears only
                // against a verified ACTIVE state licence (its absence says nothing);
                // "Takes small jobs" when the profile or reviews say small work is welcome.
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
                        if takesSmallJobs {
                            Text(contractor.reviewCount > 0 || isLicensed
                                 ? " • Takes small jobs" : "Takes small jobs")
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
    /// The screened photos still worth showing — minus any that failed to load, so
    /// a dead/stale reference never renders as a gray tile. Nil while still
    /// screening (drives the loading skeleton), like `photos`.
    private var usablePhotos: [String]? {
        guard let photos else { return nil }
        return photos.filter { !failed.contains($0) }
    }

    /// A tile's image couldn't be fetched. Drop it (the mosaic re-lays-out around
    /// the survivors), tell the parent to purge it from the cache, and — if every
    /// one of this business's photos has now failed — ask the parent to drop the
    /// business, so a listed contractor always shows a real picture.
    private func handleFailure(_ url: String) {
        guard !failed.contains(url) else { return }
        failed.insert(url)
        onPhotoUnavailable(url)
        if let photos, photos.allSatisfy({ failed.contains($0) }) {
            onNoUsablePhotos()
        }
    }

    private var mosaic: some View {
        GeometryReader { geo in
            let colW = (geo.size.width - mosaicGap) / 2   // 181 at the 402pt width
            let rowH = (mosaicHeight - mosaicGap) / 2      // 113
            Group {
                if let photos = usablePhotos, !photos.isEmpty {
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
            // Same URL the screener already downloaded, so this is normally a cache
            // hit. If it can't be fetched (a stale/dead reference), drop the tile
            // rather than show a gray container.
            PlacesImage(url: URL(string: PlacesService.photoURL(s, width: PlacesService.listPhotoWidth)),
                        onLoadResult: { ok in if !ok { handleFailure(s) } }) { placeholderFill }
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

/// A very light "Estimating price…" placeholder shown in the header while the
/// (web-grounded) estimate loads — a slow, subtle opacity pulse so it reads as
/// "working" without pulling focus. Replaced by the real range when it lands.
private struct EstimatingLabel: View {
    @State private var dim = false
    var body: some View {
        Text("Estimating price…")
            .font(.bodySmall)
            .foregroundStyle(.white.opacity(dim ? 0.35 : 0.7))
            .lineLimit(1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
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
