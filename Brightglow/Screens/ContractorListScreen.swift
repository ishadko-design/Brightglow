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
    @State private var isLoading   = false
    @State private var estimate: PriceTier? = nil

    @State private var sentToAll = false
    @State private var goGallery = false
    @State private var startContractorID: String? = nil
    /// The contractor the gallery is currently showing — used to scroll the list
    /// back to that exact spot when the user returns (they may have skipped past
    /// the one they opened).
    @State private var lastViewedID: String? = nil

    private var headerTitle: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? category : q
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
        .navigationDestination(isPresented: $goGallery) {
            ContractorGalleryScreen(
                category: category,
                searchQuery: searchQuery,
                aiResult: aiResult,
                presetCoordinate: presetCoordinate,
                preloadedContractors: contractors,
                preScreened: screenedByID,
                startContractorID: startContractorID,
                presetEstimate: estimate,
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
                            onReviews: { openReviews(for: contractor) }
                        )
                        .id(contractor.id)
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
            // Absorbs the slack so the Send-to-all button stays pinned right.
            .frame(maxWidth: .infinity, alignment: .leading)

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
            if spinner { ProgressView().tint(AppColors.accentStart).scaleEffect(1.4) }
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
    private func load() async {
        guard contractors.isEmpty else { return }
        isLoading = true

        let resolved = await ContractorLoader.resolveCoordinate(
            preset: presetCoordinate, location: location)

        if let coord = resolved {
            contractors = await ContractorLoader.fetchLive(
                category: category, searchQuery: searchQuery, near: coord)
            if !contractors.isEmpty {
                Task { @MainActor in
                    estimate = await ContractorLoader.estimate(
                        category: category, searchQuery: searchQuery, near: coord)
                }
            }
        } else {
            contractors = ContractorLoader.fallback(
                category: category, searchQuery: searchQuery)
        }
        isLoading = false

        await screenAll()
    }

    /// Screens contractors' photos concurrently (bounded), revealing each row as
    /// soon as its work photos are ready. Contractors whose whole pool is non-work
    /// imagery are dropped (same as the gallery).
    ///
    /// Screening each photo is a download + on-device Vision pass; running it one
    /// contractor at a time (and blocking on a prefetch per kept photo) made the
    /// list trickle in. Here up to `maxConcurrent` contractors screen at once and
    /// prefetch is fire-and-forget, so the first screenful appears quickly.
    private func screenAll() async {
        let pending = contractors.filter { screenedByID[$0.id] == nil }
        guard !pending.isEmpty else { return }
        let maxConcurrent = 6

        await withTaskGroup(of: (String, [String]).self) { group in
            var next = 0
            func schedule() {
                guard next < pending.count else { return }
                let c = pending[next]; next += 1
                group.addTask { (c.id, await PhotoFilter.screen(c.photos)) }
            }
            for _ in 0..<min(maxConcurrent, pending.count) { schedule() }

            for await (id, kept) in group {
                if kept.isEmpty {
                    contractors.removeAll { $0.id == id }
                } else {
                    screenedByID[id] = kept
                    // Warm the first photo for the thumbnail / gallery handoff
                    // without blocking the screening pipeline.
                    if let s = kept.first, let u = URL(string: s) {
                        Task.detached { await ImageCache.shared.prefetch(u) }
                    }
                }
                schedule()   // backfill as each finishes → steady concurrency
            }
        }
    }
}

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

                Button(action: onReviews) {
                    HStack(spacing: 8) {
                        ListStarRow(rating: contractor.rating)
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
            .padding(.horizontal, sideInset)

            // ── Horizontal photo strip — 112×136, r16, 8pt gap ────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let photos {
                        ForEach(Array(photos.enumerated()), id: \.offset) { _, s in
                            Button(action: onOpen) {
                                tile { PlacesImage(url: URL(string: s)) { placeholderFill }
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
