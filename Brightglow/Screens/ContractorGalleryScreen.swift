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

    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var location = LocationProvider()
    @State private var contractors: [Contractor] = []
    @State private var isLoading   = false
    @State private var showQuote   = false
    @State private var selectedContractor: Contractor? = nil
    @State private var estimate: PriceTier? = nil
    @State private var sentToAll   = false
    @State private var totalCount  = 0

    @State private var sheetDetent: SheetDetent = .collapsed
    @State private var sheetScrolledToTop = true
    /// Screened work-photo URLs per contractor id. nil = not yet screened
    /// (show loading); [] = no work photos (show placeholder). Populated ahead of
    /// time so a newly-surfaced contractor doesn't stall on the screen.
    @State private var screenedByID: [String: [String]] = [:]

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
                    statusView(spinner: true, text: "Finding contractors near you…")
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
                    title: headerTitle,
                    countText: contractors.isEmpty
                        ? nil
                        : "\(totalCount - contractors.count + 1)/\(totalCount) businesses",
                    sentToAll: sentToAll,
                    showSendToAll: !contractors.isEmpty,
                    onBack: { dismiss() },
                    onSendAll: {
                        guard !sentToAll else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { sentToAll = true }
                    }
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
        .task {
            await loadContractors()
            totalCount = contractors.count
        }
        // Screen the current contractor + the next couple ahead of time, so the
        // photo is ready the instant a contractor is surfaced (no load stall).
        .task(id: topContractor?.id) { await prefetchUpcoming() }
        .navigationDestination(isPresented: $showQuote) {
            QuoteRequestScreen(contractor: selectedContractor, requestSummary: headerTitle)
        }
    }

    // ── Sheet content (handle is supplied by BottomSheet) ─────────────────────
    private func sheetBody(for contractor: Contractor, bottomInset: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                infoBlock(for: contractor)
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

    private func infoBlock(for contractor: Contractor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(contractor.name)
                .font(.h3)
                .foregroundStyle(.white)
                .lineLimit(1)

            if let tier = estimate ?? contractor.priceTiers.first {
                Text("\(estimate == nil ? "Price range" : "Est. price"): $\(money(tier.min))–\(money(tier.max))")
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Stars + rating/review count → opens the contractor's Google reviews.
            Button {
                if let url = googleReviewsURL(for: contractor) { openURL(url) }
            } label: {
                HStack(spacing: 8) {
                    StarRow(rating: contractor.rating)
                    if contractor.reviewCount > 0 {
                        (Text("\(contractor.rating, specifier: "%.1f") • \(contractor.reviewCount) ")
                            + Text("reviews").underline())
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
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
                Text("Skip")
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
                ProgressView().tint(AppColors.accentStart).scaleEffect(1.4)
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
    }

    private func quoteTop() {
        selectedContractor = contractors.last
        sheetDetent = .collapsed
        if !contractors.isEmpty { contractors.removeLast() }
        showQuote = true
    }

    // ── Photo screening / prefetch ────────────────────────────────────────────
    // Screens the current contractor (shown last in the array) first, then the
    // two that will be surfaced next, warming their images into the cache. Each
    // contractor is screened at most once. Runs on contractor change, so the
    // window of prefetched contractors slides forward as the user skips.
    private func prefetchUpcoming() async {
        let upcoming = Array(contractors.suffix(3).reversed())   // current, then next two
        for contractor in upcoming {
            if screenedByID[contractor.id] != nil { continue }
            let kept = await PhotoFilter.screen(contractor.photos)
            screenedByID[contractor.id] = kept
            for s in kept {
                if let u = URL(string: s) { await ImageCache.shared.prefetch(u) }
            }
        }
    }

    // ── Data loading (mirrors SwipeScreen) ────────────────────────────────────
    private func loadContractors() async {
        guard contractors.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let resolved = await resolveCoordinate()

        if let coord = resolved {
            // We have a real location: trust the live result for that area. If it
            // comes back empty, show an empty state — do NOT mask it with the
            // location-independent mock list (that's what made changing the city,
            // e.g. to Kyiv, appear to do nothing).
            let live = await fetchLive(near: coord)
            contractors = live
            if !live.isEmpty {
                Task { @MainActor in estimate = await localEstimate(near: coord) }
            }
            return
        }
        // Only with no resolvable location at all (denied / offline) do we show
        // the built-in demo contractors.
        loadFallback()
    }

    private func resolveCoordinate() async -> CLLocationCoordinate2D? {
        if let preset = presetCoordinate { return preset }
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

    private func localEstimate(near coord: CLLocationCoordinate2D) async -> PriceTier? {
        let q   = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cat = !q.isEmpty
            ? (Category.matching(query: q).first ?? .plumbing)
            : (Category(rawValue: category) ?? .plumbing)
        let locality = await EstimateService.locality(for: coord)
        return await EstimateService.estimate(category: cat, job: q, locality: locality)
    }

    private func fetchLive(near coord: CLLocationCoordinate2D) async -> [Contractor] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return await PlacesService.fetch(searchText: q, near: coord)
        } else if let cat = Category(rawValue: category) {
            return await PlacesService.fetch(category: cat, near: coord)
        } else {
            return await PlacesService.fetch(searchText: "home repair", near: coord)
        }
    }

    private func loadFallback() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let matched = Set(Category.matching(query: q))
            contractors = mockContractors.filter { !Set($0.category).isDisjoint(with: matched) }
        } else if !category.isEmpty {
            contractors = mockContractors.filter { $0.category.map(\.rawValue).contains(category) }
        } else {
            contractors = mockContractors
        }
    }
}

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
                        .overlay(photoTapZones)
                        // Swipe left / right to cycle through the photos.
                        .contentShape(Rectangle())
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
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(active ? Color.white : Color.white.opacity(0.5),
                                            lineWidth: 1)
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

    // Left / right halves page through the photos.
    private var photoTapZones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).onTapGesture { page(-1) }
            Color.clear.contentShape(Rectangle()).onTapGesture { page(1) }
        }
        .frame(height: imageHeight)
        .frame(maxHeight: .infinity, alignment: .top)
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
// MARK: - GalleryHeader
// Matches the main screen's top bar: horizontal 16 / vertical 8 padding over the
// shared BlurredHeaderBackground.
// ─────────────────────────────────────────────────────────────────────────────

private struct GalleryHeader: View {
    let title: String
    let countText: String?
    let sentToAll: Bool
    let showSendToAll: Bool
    let onBack: () -> Void
    let onSendAll: () -> Void

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
                if let countText {
                    Text(countText)
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            // Absorbs the slack and truncates, so a long title can never push the
            // Send-to-all button off the right edge.
            .frame(maxWidth: .infinity, alignment: .leading)

            if showSendToAll {
                Button(action: onSendAll) {
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
        .padding(.horizontal, 16)
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
                            .foregroundStyle(AppColors.accentStart)
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
