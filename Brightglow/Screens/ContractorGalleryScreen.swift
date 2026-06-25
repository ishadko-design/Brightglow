import SwiftUI
import CoreLocation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ContractorGalleryScreen
//
// A redesign of the card-stack screen ("contractor gallery"). Differences from
// the original SwipeScreen, per the Figma source of truth (node 345-734 collapsed
// / 351-892 expanded):
//   • The card photo fills the entire screen (full-bleed). Rounded corners only
//     appear while the user swipes the card left/right.
//   • A solid #131315 bottom sheet (not frosted glass) carries the contractor
//     info + reviews. It drags between a collapsed and an expanded detent.
//   • The contractor logo (from the Places API) sits beside the name.
//   • The header is a fading blurred gradient with a background blur applied.
// ─────────────────────────────────────────────────────────────────────────────

struct ContractorGalleryScreen: View {
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
    @State private var totalCount  = 0

    private var visibleContractors: [Contractor] { Array(contractors.suffix(3)) }

    private var headerTitle: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppColors.bg.ignoresSafeArea()

            // ── Full-screen card stack ────────────────────────────────────────
            ZStack {
                if isLoading && contractors.isEmpty {
                    statusView(spinner: true, text: "Finding contractors near you…")
                } else if contractors.isEmpty {
                    statusView(spinner: false, text: "No more contractors")
                } else {
                    ForEach(Array(visibleContractors.enumerated()), id: \.element.id) { i, contractor in
                        let isTop = i == visibleContractors.count - 1
                        let depth = visibleContractors.count - 1 - i

                        GalleryCardView(
                            contractor: contractor,
                            estimate: estimate,
                            isTop: isTop,
                            onSkip: skipTop,
                            onQuote: quoteTop
                        )
                        // Cards behind the top one darken with depth.
                        .overlay(
                            depth > 0 ? Color.black.opacity(i == 0 ? 0.5 : 0.3) : nil
                        )
                        .zIndex(Double(i))
                        .scaleEffect(1.0 - CGFloat(depth) * 0.04, anchor: .center)
                    }
                }
            }
            .ignoresSafeArea()

            // ── Header: fading blurred gradient + background blur ─────────────
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
        }
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
    }

    // ── Top-card actions ──────────────────────────────────────────────────────
    private func skipTop() {
        withAnimation(.spring()) { if !contractors.isEmpty { contractors.removeLast() } }
    }

    private func quoteTop() {
        selectedContractor = contractors.last
        withAnimation(.spring()) { if !contractors.isEmpty { contractors.removeLast() } }
        showQuote = true
    }

    // ── Data loading (mirrors SwipeScreen) ────────────────────────────────────
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
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GalleryHeader
// Fading blurred gradient with a background blur (Figma: "Blurred bg" rect with
// BACKGROUND_BLUR 8 + a top→bottom gradient that fades out).
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
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.h2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let countText {
                    Text(countText)
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer(minLength: 0)

            if showSendToAll {
                Button(action: onSendAll) {
                    Text(sentToAll ? "Sent ✓" : "Send to all")
                        .font(.h4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 29)
                        .background(AppColors.btnSecondary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            // Background blur of the photo behind, masked to fade out downward, with
            // a dark gradient for legibility under the title.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [AppColors.bg.opacity(0.55), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.55),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(height: 132)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GalleryCardView
// Full-bleed photo + a draggable solid bottom sheet. Horizontal swipe = skip /
// request quote; corners round only while swiping.
// ─────────────────────────────────────────────────────────────────────────────

struct GalleryCardView: View {
    let contractor: Contractor
    var estimate: PriceTier? = nil
    let isTop: Bool
    let onSkip: () -> Void
    let onQuote: () -> Void

    @State private var offset: CGSize = .zero
    @State private var photoIndex = 0
    @State private var screenedPhotos: [String]? = nil
    @State private var expanded = false
    @GestureState private var sheetDrag: CGFloat = 0   // live vertical drag, +down

    private var photos: [String] { screenedPhotos ?? contractor.photos }
    private var reviews: [Review] { Array(contractor.reviews.prefix(5)) }
    private var swipeProgress: Double { Double(offset.width) / 150 }
    private var isSwiping: Bool { abs(offset.width) > 1 }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let collapsedH = H * 0.25   // sits ~30% lower than the first pass
            let expandedH  = H * 0.93
            let base = expanded ? expandedH : collapsedH
            let sheetH = min(expandedH, max(collapsedH, base - sheetDrag))
            // 0 collapsed → 1 expanded, used to fade the photo dots out.
            let expandProgress = (sheetH - collapsedH) / max(1, expandedH - collapsedH)

            let photoURL = photos.indices.contains(photoIndex)
                ? URL(string: photos[photoIndex]) : nil

            ZStack(alignment: .bottom) {

                // ── 1. Full-bleed photo with tap-to-page zones ────────────────
                PlacesImage(url: photoURL) { AppColors.cardFallback }
                    .scaledToFill()
                    .frame(width: W, height: H)
                    .clipped()
                    .animation(.easeInOut(duration: 0.2), value: photoIndex)
                    .overlay(photoTapZones)
                    // Horizontal swipe lives on the photo so it never fights the
                    // sheet's vertical drag / review scrolling.
                    .simultaneousGesture(isTop ? swipeGesture : nil)

                // ── 2. Photo pagination dots, just above the sheet ────────────
                if photos.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(photos.indices, id: \.self) { i in
                            Circle()
                                .fill(i == photoIndex ? AppColors.dotActive : AppColors.dotInactive)
                                .frame(width: 8, height: 8)
                                .animation(.easeInOut(duration: 0.2), value: photoIndex)
                        }
                    }
                    .padding(.bottom, sheetH + 16)
                    .opacity(1 - expandProgress)
                    .allowsHitTesting(false)
                }

                // ── 3. Solid bottom sheet ─────────────────────────────────────
                bottomSheet(width: W, height: sheetH)
            }
            .frame(width: W, height: H)
            // Corners round only while swiping the card left/right.
            .clipShape(RoundedRectangle(cornerRadius: isSwiping ? 32 : 0, style: .continuous))
            .shadow(color: .black.opacity(isSwiping ? 0.25 : 0), radius: 8, x: 0, y: 4)
        }
        .ignoresSafeArea()
        .rotationEffect(.degrees(isTop ? swipeProgress * 4 : 0))
        .offset(isTop ? offset : .zero)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: expanded)
        .task(priority: .background) {
            guard screenedPhotos == nil else { return }
            let current = photos.indices.contains(photoIndex) ? photos[photoIndex] : nil
            let kept = await PhotoFilter.screen(contractor.photos)
            screenedPhotos = kept
            photoIndex = current.flatMap { kept.firstIndex(of: $0) } ?? 0
        }
    }

    // Left / right halves page through the photos.
    private var photoTapZones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).onTapGesture { page(-1) }
            Color.clear.contentShape(Rectangle()).onTapGesture { page(1) }
        }
    }

    private func page(_ dir: Int) {
        guard photos.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            photoIndex = (photoIndex + dir + photos.count) % photos.count
        }
    }

    // ── Bottom sheet ──────────────────────────────────────────────────────────
    private func bottomSheet(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Grab handle — also the drag target for expand / collapse.
            Capsule()
                .fill(AppColors.handle)
                .frame(width: 44, height: 8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .gesture(sheetDragGesture)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    infoBlock
                    ForEach(reviews) { ReviewRowGallery(review: $0) }
                    Color.clear.frame(height: 112) // clear the pinned CTAs
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .scrollDisabled(!expanded)
            // While collapsed, scrolling is off so a drag on the body pulls the
            // sheet up instead. Once expanded, the ScrollView takes over.
            .simultaneousGesture(expanded ? nil : sheetDragGesture)
        }
        .frame(width: width, height: height, alignment: .top)
        .background(AppColors.bg)                       // solid color sheet
        .clipShape(.rect(topLeadingRadius: 24, topTrailingRadius: 24))
        .overlay(alignment: .bottom) { ctaFooter(width: width) }
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(contractor.name)
                .font(.h2)
                .foregroundStyle(.white)
                .lineLimit(1)

            if let tier = estimate ?? contractor.priceTiers.first {
                Text("\(estimate == nil ? "Price range" : "Est. price"): $\(money(tier.min))–\(money(tier.max))")
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.5))
            }

            HStack(spacing: 8) {
                StarRow(rating: contractor.rating)
                if contractor.reviewCount > 0 {
                    Text("\(contractor.rating, specifier: "%.1f") • \(contractor.reviewCount) reviews")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func money(_ v: Int) -> String { v >= 1000 ? "\(v / 1000)k" : "\(v)" }

    // Pinned Skip / Request quote — a centered, content-sized button group on a
    // solid floor that fades up into the reviews (Figma "Footer": Skip 99×48 +
    // 8pt gap + Request quote, radius 32, Lato 700/18).
    private func ctaFooter(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button(action: onSkip) {
                Text("Skip")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(width: 99, height: 48)
                    .background(AppColors.btnSecondary, in: Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onQuote) {
                Text("Request quote")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .fixedSize()                 // hug the text, don't stretch
                    .padding(.horizontal, 28)
                    .frame(height: 48)
                    .background(AppColors.btnPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)              // center the group
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(width: width)
        .background(alignment: .bottom) {
            // Solid floor behind the buttons with a short fade at the top edge.
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, AppColors.bg],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                AppColors.bg
            }
            .allowsHitTesting(false)
        }
    }

    // ── Gestures ──────────────────────────────────────────────────────────────
    private var sheetDragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .updating($sheetDrag) { v, state, _ in state = v.translation.height }
            .onEnded { v in
                // Up → expand, down → collapse (with a velocity assist).
                if v.translation.height < -40 { expanded = true }
                else if v.translation.height > 40 { expanded = false }
            }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                offset = CGSize(width: v.translation.width, height: 0)
            }
            .onEnded { v in
                let t: CGFloat = 110
                if v.translation.width > t {
                    withAnimation(.spring()) { offset = CGSize(width: 700, height: 0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onQuote() }
                } else if v.translation.width < -t {
                    withAnimation(.spring()) { offset = CGSize(width: -700, height: 0) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onSkip() }
                } else {
                    withAnimation(.spring()) { offset = .zero }
                }
            }
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
                Text(review.text)
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                StarRow(rating: Double(review.rating))
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
