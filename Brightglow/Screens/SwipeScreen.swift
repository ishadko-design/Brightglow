import SwiftUI
import CoreLocation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Scroll offset preference key
// ─────────────────────────────────────────────────────────────────────────────

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SwipeScreen
// ─────────────────────────────────────────────────────────────────────────────

struct SwipeScreen: View {
    var category: String = ""
    var searchQuery: String = ""
    var aiResult: AIResult? = nil

    @Environment(\.dismiss) var dismiss
    @StateObject private var location = LocationProvider()
    @State private var contractors: [Contractor] = []
    @State private var isLoading   = false
    @State private var showQuote   = false
    @State private var selectedContractor: Contractor? = nil
    @State private var estimate: PriceTier? = nil
    @State private var sentToAll   = false
    /// Total businesses found, captured at load so the header count stays steady
    /// as the user swipes cards away.
    @State private var totalCount  = 0

    var visibleContractors: [Contractor] {
        Array(contractors.suffix(3))
    }

    private var headerTitle: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
    }

    private func loadContractors() async {
        guard contractors.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        if let coord = await location.currentCoordinate() {
            async let liveTask     = fetchLive(near: coord)
            async let estimateTask = localEstimate(near: coord)
            let live = await liveTask
            estimate = await estimateTask
            if !live.isEmpty { contractors = live; return }
        }
        loadFallback()
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

    // Actions applied to the top card
    private func skipTop() {
        withAnimation(.spring()) {
            if !contractors.isEmpty { contractors.removeLast() }
        }
    }

    private func quoteTop() {
        selectedContractor = contractors.last
        withAnimation(.spring()) {
            if !contractors.isEmpty { contractors.removeLast() }
        }
        showQuote = true
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header: ← + (title / count) ......... Send to all ─────────────
            HStack(alignment: .center, spacing: 12) {
                Button(action: { dismiss() }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 0) {
                    Text(headerTitle)
                        .font(.h2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !contractors.isEmpty {
                        Text("\(totalCount) Businesses")
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer(minLength: 0)

                if !contractors.isEmpty {
                    Button {
                        guard !sentToAll else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { sentToAll = true }
                    } label: {
                        Text(sentToAll ? "Sent ✓" : "Send to all")
                            .font(.h4)
                            .foregroundStyle(AppColors.ctaBlue)
                            .frame(height: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            // ── Card stack ────────────────────────────────────────────────────
            ZStack {
                if isLoading && contractors.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(AppColors.accentStart)
                            .scaleEffect(1.4)
                        Text("Finding contractors near you…")
                            .font(.h3)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                } else if contractors.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 60))
                            .foregroundStyle(AppColors.textSecondary)
                        Text("No more contractors")
                            .font(.h3)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                } else {
                    ForEach(Array(visibleContractors.enumerated()), id: \.element.id) { i, contractor in
                        let isTop  = i == visibleContractors.count - 1
                        let depth  = visibleContractors.count - 1 - i

                        ContractorCardView(
                            contractor: contractor,
                            estimate: estimate,
                            isTop: isTop,
                            onSkip: skipTop,
                            onQuote: quoteTop
                        )
                        // Cards behind the top one get a black overlay: 60% each,
                        // and 80% for the last (back-most) card in the stack.
                        // Applied before the geometric transforms so it moves with
                        // the card (incl. the 8px peek), rather than staying put.
                        .overlay(
                            depth > 0
                                ? RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(Color.black.opacity(i == 0 ? 0.8 : 0.6))
                                : nil
                        )
                        .zIndex(Double(i))
                        .scaleEffect(1.0 - CGFloat(depth) * 0.05, anchor: .top)
                        // Each card peeks only 8px above the one in front.
                        .offset(y: CGFloat(-depth) * 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await loadContractors()
            totalCount = contractors.count
        }
        .navigationDestination(isPresented: $showQuote) {
            QuoteRequestScreen(contractor: selectedContractor, requestSummary: headerTitle)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractorCardView
// Image fills the card as a background; content (info + up to 10 reviews) scrolls
// over it. As the user scrolls up, a dark fade grows over the image so the reviews
// stay legible. Buttons live in SwipeScreen; this view only handles the L/R swipe.
// ─────────────────────────────────────────────────────────────────────────────

struct ContractorCardView: View {
    let contractor: Contractor
    var estimate: PriceTier? = nil
    let isTop: Bool
    let onSkip: () -> Void
    let onQuote: () -> Void

    @State private var offset: CGSize = .zero
    @State private var photoIndex = 0
    @State private var screenedPhotos: [String]? = nil
    @State private var scrollOffset: CGFloat = 0
    /// Direction lock for the current drag: true = horizontal swipe, false =
    /// vertical scroll (handed to the ScrollView), nil = not yet decided.
    @State private var horizontalDrag: Bool? = nil

    private var photos: [String] { screenedPhotos ?? contractor.photos }
    // Google Places returns at most 5 reviews per business.
    private var reviews: [Review] { Array(contractor.reviews.prefix(5)) }
    var swipeProgress: Double { Double(offset.width) / 150 }

    var body: some View {
        GeometryReader { geo in
            let cardW = geo.size.width
            let cardH = geo.size.height
            // Image shows through the top portion in the default (unscrolled) state.
            // The frosted footer panel begins here and scrolls up over the image.
            let imagePeek = cardH * 0.60
            // Height of the pinned frosted buttons bar at the bottom of the card.
            // 48pt buttons + 12pt top/bottom padding = 72 (4px grid).
            let buttonBarH: CGFloat = 72
            // As the user scrolls up, the frosted glass spreads to cover the whole
            // card: 0 at rest → 1 once scrolled roughly past the image area.
            let coverProgress = min(1, max(0, scrollOffset / (imagePeek * 0.85)))

            let photoURL = photos.indices.contains(photoIndex)
                ? URL(string: photos[photoIndex]) : nil

            ZStack(alignment: .top) {

                // ── 1. Photo — fills the whole card ───────────────────────────
                PlacesImage(url: photoURL) {
                    AppColors.cardFallback
                }
                .scaledToFill()
                .frame(width: cardW, height: cardH)
                .clipped()
                .animation(.easeInOut(duration: 0.2), value: photoIndex)

                // ── 2. Full-card frosted cover — intensifies as the user scrolls,
                //     so the glass gradually occupies the entire card surface. ───
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    AppColors.bg.opacity(0.45)
                }
                .frame(width: cardW, height: cardH)
                .opacity(coverProgress)
                .allowsHitTesting(false)

                // ── 4. Scrolling content over the image ───────────────────────
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {

                        // Spacer keeps the panel pinned near the image bottom at
                        // rest. It doubles as the photo-nav tap area: taps page the
                        // photos, vertical drags still scroll (tap ≠ drag inside a
                        // ScrollView), so both gestures coexist.
                        HStack(spacing: 0) {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture {
                                    guard photos.count > 1 else { return }
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        photoIndex = (photoIndex - 1 + photos.count) % photos.count
                                    }
                                }
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture {
                                    guard photos.count > 1 else { return }
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        photoIndex = (photoIndex + 1) % photos.count
                                    }
                                }
                        }
                        .frame(height: imagePeek)

                        // Frosted footer panel: info + reviews on a glass background
                        // that fades in from the top and scrolls up over the image.
                        VStack(alignment: .leading, spacing: 0) {

                            // Info block
                            VStack(alignment: .leading, spacing: 8) {
                                if photos.count > 1 {
                                    HStack(spacing: 8) {
                                        ForEach(photos.indices, id: \.self) { i in
                                            Circle()
                                                .fill(i == photoIndex
                                                      ? AppColors.dotActive
                                                      : AppColors.dotInactive)
                                                .frame(width: 8, height: 8)
                                                .animation(.easeInOut(duration: 0.2), value: photoIndex)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.bottom, 4)
                                }

                                Text(contractor.name)
                                    .font(.h3)
                                    .foregroundStyle(.white)

                                if let tier = estimate ?? contractor.priceTiers.first {
                                    Text("\(estimate == nil ? "Price range" : "Est.") $\(tier.min >= 1000 ? "\(tier.min/1000)k" : "\(tier.min)")–\(tier.max >= 1000 ? "\(tier.max/1000)k" : "\(tier.max)")")
                                        .font(.bodyLight)
                                        .foregroundStyle(.white.opacity(0.5))
                                }

                                HStack(spacing: 4) {
                                    ForEach(0..<5) { i in
                                        Image(systemName: i < Int(contractor.rating.rounded()) ? "star.fill" : "star")
                                            .resizable()
                                            .frame(width: 12, height: 12)
                                            .foregroundStyle(i < Int(contractor.rating.rounded())
                                                             ? AppColors.starFilled
                                                             : AppColors.starEmpty)
                                    }
                                    if contractor.reviewCount > 0 {
                                        Text("\(contractor.rating, specifier: "%.1f") · \(contractor.reviewCount) reviews")
                                            .font(.bodySmall)
                                            .foregroundStyle(.white.opacity(0.5))
                                            .padding(.leading, 4)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 28)
                            .padding(.bottom, 0)

                            // Reviews (up to 10) — 4px below the info block.
                            VStack(spacing: 0) {
                                ForEach(reviews) { review in
                                    ReviewRow(review: review)
                                }
                            }
                            .padding(.top, 4)

                            // Clear the pinned buttons bar so the last review is reachable.
                            Color.clear.frame(height: buttonBarH + 12)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            // Rest-state footer glass, masked with a tall eased fade
                            // so the frost blends smoothly out of the photo instead of
                            // ending on a hard edge. Fades out as the full-card cover
                            // takes over on scroll, so the final frost stays uniform.
                            ZStack {
                                Rectangle().fill(.ultraThinMaterial)
                                AppColors.bg.opacity(0.45)
                            }
                            .mask(
                                VStack(spacing: 0) {
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0.0),
                                            .init(color: .black.opacity(0.15), location: 0.45),
                                            .init(color: .black.opacity(0.6), location: 0.75),
                                            .init(color: .black, location: 1.0)
                                        ],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                    .frame(height: 180)
                                    Color.black
                                }
                            )
                            // Extend the frosted glass 80pt above the panel (over the
                            // photo) so the blur is already present above the name and
                            // estimate, fading smoothly up into the image.
                            .padding(.top, -80)
                            .opacity(1 - coverProgress)
                            .allowsHitTesting(false)
                        }
                    }
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: inner.frame(in: .named("cardScroll")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "cardScroll")
                .onPreferenceChange(ScrollOffsetKey.self) { value in
                    scrollOffset = max(0, -value)
                }

                // ── 4. Buttons — pinned to the card bottom, above everything,
                //     on their own frosted-glass bar. Comments scroll beneath. ──
                let gap:   CGFloat = 10
                let availW         = cardW - 32
                let skipW          = (availW - gap) * (131.0 / 323.0)
                let quoteW         = (availW - gap) * (192.0 / 323.0)

                HStack(spacing: gap) {
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(.h3)
                            .foregroundStyle(.white)
                            .frame(width: skipW, height: 48)
                    }
                    .buttonStyle(.frosted)

                    Button(action: onQuote) {
                        Text("Request quote")
                            .font(.h3)
                            .foregroundStyle(.white)
                            .frame(width: quoteW, height: 48)
                    }
                    .buttonStyle(.gradient)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(width: cardW, height: buttonBarH, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .background(alignment: .bottom) {
                    // Frosted glass bar that fades in from its top edge.
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        AppColors.bg.opacity(0.35)
                    }
                    .frame(height: buttonBarH + 24)
                    .mask(
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 24)
                            Color.black
                        }
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: cardW, height: cardH)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 4)
        }
        .rotationEffect(.degrees(isTop ? swipeProgress * 4 : 0))
        .offset(isTop ? offset : .zero)
        // simultaneousGesture lets the inner ScrollView keep handling vertical
        // drags (reveal reviews) while we capture horizontal-dominant swipes.
        .simultaneousGesture(isTop ? swipeGesture : nil)
        .task(priority: .background) {
            guard screenedPhotos == nil else { return }
            let current = photos.indices.contains(photoIndex) ? photos[photoIndex] : nil
            let kept = await PhotoFilter.screen(contractor.photos)
            screenedPhotos = kept
            photoIndex = current.flatMap { kept.firstIndex(of: $0) } ?? 0
        }
    }

    var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                // Lock to horizontal the first time the drag is clearly sideways;
                // a vertical-dominant drag is left entirely to the ScrollView.
                if horizontalDrag == nil {
                    horizontalDrag = abs(v.translation.width) > abs(v.translation.height) * 1.2
                }
                if horizontalDrag == true {
                    offset = CGSize(width: v.translation.width, height: 0)
                }
            }
            .onEnded { v in
                defer { horizontalDrag = nil }
                guard horizontalDrag == true else { return }   // it was a scroll

                let t: CGFloat = 110
                if v.translation.width > t {
                    withAnimation(.spring()) { offset = CGSize(width: 600, height: 0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onQuote() }
                } else if v.translation.width < -t {
                    withAnimation(.spring()) { offset = CGSize(width: -600, height: 0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onSkip() }
                } else {
                    withAnimation(.spring()) { offset = .zero }
                }
            }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ReviewRow
// ─────────────────────────────────────────────────────────────────────────────

private struct ReviewRow: View {
    let review: Review

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            Group {
                if let urlStr = review.authorPhotoURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            initialsCircle
                        }
                    }
                } else {
                    initialsCircle
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                // Same size as the review body (14), semi-bold.
                Text(review.author)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Text(review.text)
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    ForEach(0..<5) { i in
                        Image(systemName: i < review.rating ? "star.fill" : "star")
                            .resizable()
                            .frame(width: 12, height: 12)
                            .foregroundStyle(i < review.rating ? AppColors.starFilled : AppColors.starEmpty)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
