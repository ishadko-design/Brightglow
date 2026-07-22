import SwiftUI

/// The business's home in the app (Figma 1096:5241): an at-a-glance count of who
/// looked, who got in touch, and how ready their page is.
///
/// Hosts both halves of the business area as peer tabs — Dashboard and Settings
/// (the page editor, `BusinessProfileScreen` embedded). The requests themselves
/// sit one level down, behind the tiles' "View" buttons.
///
/// Reached two ways: from the "For business" row in Profile, and from a lead
/// email's "reply in the app" deep link — which lands the business straight in
/// the request thread. The "finish your page" nudge is shown on the inbox when
/// they exit a thread (see `ConversationsListScreen` / `BusinessStore.consumeNudge`),
/// not here.
struct BusinessDashboardScreen: View {
    @EnvironmentObject private var store: BusinessStore
    @EnvironmentObject private var chatRouter: ChatRouter
    @Environment(\.dismiss) private var dismiss

    /// The two halves of the business area (Figma 1096:5241 / 1096:5699). These
    /// are peer tabs, not a push — Settings is always one tap away.
    enum Tab: Hashable { case dashboard, settings }

    @State private var openConvoID: UUID? = nil
    @State private var showRequests = false
    @State private var tab: Tab = .dashboard

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .preferredColorScheme(.dark)
        .navigationDestination(item: $openConvoID) { id in
            if let convo = store.selected?.leads.first(where: { $0.id == id }) {
                ChatThreadScreen(conversation: convo)
            }
        }
        .navigationDestination(isPresented: $showRequests) {
            BusinessRequestsScreen()
        }
        .task {
            if store.businesses.isEmpty { await store.load() }
            applyPendingDeepLink()
        }
        .onChange(of: chatRouter.targetPublicID) { _, _ in applyPendingDeepLink() }
    }

    // MARK: - Header

    /// The saved display name once loaded, else the name derived from the lead.
    private var headerName: String {
        if let n = store.profile?.displayName, !n.isEmpty { return n }
        return store.selected?.name ?? "Your business"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: { dismiss() }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Text(headerName)
                    .font(.h2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                // Figma puts a profile icon here, but the Settings tab it would
                // open is already one of the two tabs directly below — so it's a
                // second control for a destination that's never more than one tap
                // away. Left out.
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)

            SegmentedTabs(
                tabs: [(.dashboard, "Dashboard"), (.settings, "Settings")],
                selection: $tab
            )

            // Accepting-new-work — mirrors the web dashboard's header toggle.
            // Writes through immediately (no Save button here); the store updates
            // optimistically and reverts on failure. Hidden until a page loads.
            if tab == .dashboard, store.selected != nil {
                HStack(spacing: 12) {
                    Text("Accepting new work")
                        .font(.bodyLight).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.profile?.acceptingWork ?? true },
                        set: { on in Task { await store.setAcceptingWork(on) } }
                    ))
                    .labelsHidden()
                    .tint(AppColors.toggleOn)
                    .disabled(store.profile == nil)
                }
                .padding(.horizontal, 16)
            }

            // Switch between claimed businesses (only when there's more than one).
            if tab == .dashboard, store.businesses.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.businesses) { biz in
                            businessChip(biz)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.top, 8)
    }

    private func businessChip(_ biz: BusinessService.OwnedBusiness) -> some View {
        let active = biz.placeId == store.selectedPlaceId
        return Button {
            Task { await store.select(biz.placeId) }
        } label: {
            Text(biz.name)
                .font(.h4)
                .foregroundStyle(active ? .white : .white.opacity(0.6))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(
                    active ? Color.white.opacity(0.12) : Color.white.opacity(0.04),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.loading && store.selected == nil {
            centered { ProgressView().tint(.white) }
        } else if store.loadError {
            centered {
                VStack(spacing: 16) {
                    Text("Couldn't load your business.")
                        .font(.bodyLight).foregroundStyle(.white.opacity(0.7))
                    Button(action: { Task { await store.load() } }) {
                        Text("Try again")
                            .font(.h4).foregroundStyle(.white)
                            .padding(.horizontal, 24).frame(height: 48)
                            .secondaryButtonBackground()
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            switch tab {
            case .dashboard:
                // Figma 1096:5241 — the dashboard is the tiles and the readiness
                // card, nothing else. The requests live behind the Leads/Requests
                // "View" buttons (BusinessRequestsScreen), not inline here.
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        statTiles
                        if !isComplete { readinessCard }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            case .settings:
                // Figma 1096:5699 — the page editor as a peer tab, sharing this
                // screen's header and tab pill rather than pushing its own.
                BusinessProfileScreen(placeId: store.selectedPlaceId, embedded: true)
            }
        }
    }

    // MARK: - Stats

    private var leads: [Conversation] { store.selected?.leads ?? [] }
    private var replyNeeded: Int { leads.filter { $0.lastMessageIncoming }.count }
    private var views: Int { store.selected?.views ?? 0 }
    private var readiness: Double { store.profile.map { BusinessService.completeness($0) } ?? 0 }
    private var isComplete: Bool { readiness >= 1 }

    /// Figma 1096:5241 — three tiles across: Views, Leads, Requests. "Requests"
    /// is the count still waiting on a reply, so it carries the gold tint and the
    /// primary button; the other two are informational.
    private var statTiles: some View {
        HStack(spacing: 16) {
            statTile(label: "Views", value: "\(views)", tint: .white)
            statTile(label: "Leads", value: "\(leads.count)", tint: .white,
                     action: leads.isEmpty ? nil : .init(title: "View", primary: false) {
                         showRequests = true
                     })
            statTile(label: "Requests",
                     value: "\(replyNeeded)",
                     tint: replyNeeded > 0 ? AppColors.starFilled : .white,
                     action: replyNeeded == 0 ? nil : .init(title: "View", primary: true) {
                         showRequests = true
                     })
        }
        .padding(.horizontal, 16)
    }

    /// A tile's optional call to action. `primary` is the filled blue treatment
    /// Figma gives the Requests tile; everything else is the gray capsule.
    struct TileAction {
        let title: String
        let primary: Bool
        let run: () -> Void
    }

    /// Label above value, both centered (Figma: Lato 14/700 gray50 over Lato 24/800).
    private func statTile(label: String, value: String, tint: Color,
                          action: TileAction? = nil) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.h4)
                    .foregroundStyle(AppColors.textSecondary)
                Text(value)
                    .font(.h2)
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            if let action { tileButton(action) }
        }
        .frame(maxWidth: .infinity, minHeight: 125)
        .padding(16)
        .background(AppColors.bgOverlay,
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1.5)
        )
    }

    /// Figma: 32-high capsule, Lato 14/700, 16pt horizontal padding.
    private func tileButton(_ action: TileAction) -> some View {
        Button(action: action.run) {
            Text(action.title)
                .font(.h4)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(action.primary ? AppColors.ctaPrimary : AppColors.ctaSecondary,
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// "Profile readiness" prompt — shown only while the page is incomplete.
    private var readinessCard: some View {
        // Figma: label above value, then a gray "Settings" capsule — same shape as
        // the stat tiles, full width.
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("Profile readiness")
                    .font(.h4).foregroundStyle(AppColors.textSecondary)
                Text("\(Int(readiness * 100))%")
                    .font(.h2).foregroundStyle(.white)
            }
            tileButton(.init(title: "Settings", primary: false) {
                withAnimation(.easeOut(duration: 0.18)) { tab = .settings }
            })
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(AppColors.bgOverlay,
                    in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1.5)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Helpers

    /// Honor a chat deep link that targets a request: focus the business it
    /// belongs to and open the thread. A bare `/chat` opens the latest.
    private func applyPendingDeepLink() {
        #if DEBUG
        print("🏢 dashboard applyDeepLink: businesses=\(store.businesses.count) target=\(chatRouter.targetPublicID ?? "nil") latest=\(chatRouter.openLatestRequested) leadCounts=\(store.businesses.map { $0.leads.count })")
        #endif
        guard !store.businesses.isEmpty else { return }

        if let target = chatRouter.targetPublicID {
            for biz in store.businesses where biz.leads.contains(where: { $0.publicId == target }) {
                chatRouter.targetPublicID = nil
                chatRouter.openLatestRequested = false
                Task {
                    await store.select(biz.placeId)
                    openConvoID = biz.leads.first(where: { $0.publicId == target })?.id
                    #if DEBUG
                    print("🏢 dashboard opening thread \(target) → convo=\(openConvoID?.uuidString ?? "nil")")
                    #endif
                }
                return
            }
            #if DEBUG
            print("🏢 dashboard: target \(target) not among my business leads — left for customer inbox")
            #endif
            return   // target isn't one of my business leads — leave it for the customer inbox
        }

        if chatRouter.openLatestRequested {
            chatRouter.openLatestRequested = false
            openConvoID = store.selected?.leads.first?.id
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }.frame(maxWidth: .infinity)
    }
}
