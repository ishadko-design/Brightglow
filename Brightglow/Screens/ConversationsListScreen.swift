import SwiftUI

/// The user's inbox — every request they've sent (and, if they're also a
/// business, every request they've received) as a tappable conversation.
/// Reached from the header chat icon on the main screen.
struct ConversationsListScreen: View {
    @Environment(\.dismiss) private var dismiss
    /// A chat deep link may ask us to jump straight into a thread (the last one,
    /// or a specific one by public_id). Consumed after the list loads.
    @EnvironmentObject private var chatRouter: ChatRouter
    /// Drives the "finish your page" nudge for a business viewing its inbox.
    @EnvironmentObject private var businessStore: BusinessStore

    @State private var conversations: [Conversation] = []
    @State private var unreadIDs: Set<UUID> = []
    /// Business logo URLs by conversation id, resolved after load (best-effort).
    @State private var logoByID: [UUID: URL] = [:]
    @State private var loading = true
    @State private var loadError = false
    /// Thread to push. Held by id (not the value) so it stays `Hashable` for
    /// `navigationDestination(item:)` — same pattern as ContractorListScreen.
    @State private var openConvoID: UUID? = nil
    /// Page-completion nudge shown when a business exits a request thread back to
    /// this inbox with a still-incomplete page (once per session).
    @State private var showNudge = false
    /// Pushes the business page editor when they tap "Finish my page".
    @State private var showEditor = false

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
            if let convo = conversations.first(where: { $0.id == id }) {
                ChatThreadScreen(conversation: convo)
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            BusinessProfileScreen(placeId: businessStore.selectedPlaceId)
        }
        .task { await load() }
        // Fires again when a thread is popped — a reviewed conversation is now
        // read, so recompute which rows still show the unread dot. Same moment a
        // business, having just exited a request thread, gets the one-per-session
        // nudge to finish its page (guarded to incomplete pages in the store).
        .onAppear {
            refreshUnread()
            if businessStore.consumeNudge(for: businessStore.selectedPlaceId) { showNudge = true }
        }
        .sheet(isPresented: $showNudge) {
            nudgeSheet
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppColors.bg)
        }
        // A deep link that lands while the inbox is already up (targetPublicID /
        // openLatestRequested set after the initial load) still opens its thread.
        .onChange(of: chatRouter.targetPublicID) { _, _ in applyPendingDeepLink() }
        .onChange(of: chatRouter.openLatestRequested) { _, _ in applyPendingDeepLink() }
    }

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Text("Messages")
                .font(.h2)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            centered { ProgressView().tint(.white) }
        } else if loadError {
            centered {
                VStack(spacing: 16) {
                    Text("Couldn't load your messages.")
                        .font(.bodyLight)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                    // Large secondary CTA (matches the app's secondary buttons)
                    // instead of a small text link, so a failed load has a clear,
                    // tappable retry.
                    Button(action: { Task { await load() } }) {
                        Text("Try again")
                            .font(.h4)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .frame(height: 48)
                            .secondaryButtonBackground()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
            }
        } else if conversations.isEmpty {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("No messages yet")
                        .font(.h3)
                        .foregroundStyle(.white)
                    Text("When you send a request, your conversation with the business shows up here.")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        } else {
            // Native iOS swipe-to-delete (Contacts/Mail-style), styled transparent
            // so the custom Figma cell design shows through. Left-swipe isn't used
            // for anything else here, so the standard gesture is unambiguous.
            List {
                ForEach(conversations) { convo in
                    ConversationRow(conversation: convo,
                                    unread: unreadIDs.contains(convo.id),
                                    logoURL: logoByID[convo.id])
                        .contentShape(Rectangle())
                        .onTapGesture { openConvoID = convo.id }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { delete(convo) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowSpacing(4)                       // Figma node 783:2224: 4 between cells
            .padding(.top, 8)
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    /// Bottom-sheet nudge a business sees on returning to its inbox after exiting
    /// a request thread with an unfinished page — a prompt to complete it, since
    /// a full page wins more of the requests it's shown.
    private var nudgeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Get more leads")
                .font(.h2).foregroundStyle(.white)
            Text("Businesses with a complete page — photos, services and prices — win more of the requests they're shown. Yours is almost there.")
                .font(.bodyLight).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: {
                showNudge = false
                showEditor = true
            }) {
                Text("Finish my page")
                    .font(.h4).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(AppColors.ctaPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: { showNudge = false }) {
                Text("Later")
                    .font(.h4).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        loadError = false
        do {
            conversations = try await ChatService.conversations()
            refreshUnread()
            loading = false
            applyPendingDeepLink()   // jump into the requested thread, if any
            // Resolve business logos for the avatars — best-effort and cached, so
            // they pop in a beat after the list without blocking it.
            let logos = await ChatService.resolveLogos(conversations)
            if !logos.isEmpty { logoByID = logos }
        } catch {
            // Surface the real cause of "nothing loads" (bad JWT, RLS, a broken
            // embed, transport) instead of only flipping to the error state.
            #if DEBUG
            print("💬 conversations load failed — \(error)")
            #endif
            loading = false
            loadError = true
        }
    }

    /// Honor a pending chat deep link once the list is loaded: open the named
    /// thread (by public_id), or the most recent one for a bare `/chat` link.
    /// No-op until conversations are in, and self-clearing so it fires once.
    private func applyPendingDeepLink() {
        guard !loading, !conversations.isEmpty else { return }

        if let target = chatRouter.targetPublicID {
            chatRouter.targetPublicID = nil
            chatRouter.openLatestRequested = false
            if let convo = conversations.first(where: { $0.publicId == target }) {
                openConvoID = convo.id
            }
            return
        }

        if chatRouter.openLatestRequested {
            chatRouter.openLatestRequested = false
            // conversations arrive sorted newest-first (ChatService), so .first
            // is the last active thread.
            openConvoID = conversations.first?.id
        }
    }

    /// Recompute the unread set from the (local) per-thread read timestamps.
    private func refreshUnread() {
        unreadIDs = Set(conversations.filter(ChatService.isUnread).map(\.id))
    }

    /// Swipe-to-delete: hide the conversation from this inbox (local per-device,
    /// like read state — the underlying lead is untouched, so the business still
    /// sees the thread).
    private func delete(_ convo: Conversation) {
        ChatService.hideConversation(convo.id)
        withAnimation {
            conversations.removeAll { $0.id == convo.id }
        }
        unreadIDs.remove(convo.id)
    }
}

/// One row in the inbox — Figma node 783:2224 "List cell". Rounded 44pt avatar,
/// title + last-message preview, and a gold unread dot. Unread rows get a faint
/// white fill and a full-opacity preview; read rows are transparent + dimmed.
private struct ConversationRow: View {
    let conversation: Conversation
    /// Unread until the viewer opens the thread — resolved by the list from
    /// per-thread read state so a reviewed conversation drops its indicator.
    let unread: Bool
    /// The business's hosted logo, when resolved — drawn in place of the generic
    /// business icon. Nil for business-viewed rows and businesses without a logo.
    let logoURL: URL?

    var body: some View {
        HStack(spacing: 12) {                        // Figma: gap 12
            // The customer sees the business (logo); the business sees each
            // customer as a distinct initial tile — a shared business logo would
            // make every received request look identical.
            avatar
                // Figma moves the unread dot onto the avatar's bottom-right corner,
                // sitting in a notch. The bg-colored ring reproduces the cutout so
                // the gold dot reads as punched into the tile.
                .overlay(alignment: .bottomTrailing) {
                    if unread {
                        Circle()                         // Figma: 12×12 badge, #D4A600
                            .fill(AppColors.starFilled)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(AppColors.bg, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {   // Figma: gap 4
                Text(conversation.title)
                    .font(.custom("Lato-Bold", size: 17))   // Figma: Lato Bold 700 / 17
                    .foregroundStyle(Color(hex: "#ECEBED"))
                    .lineLimit(1)
                Text(conversation.lastMessage ?? "No messages yet")
                    .font(.bodySmall)                        // Figma: Poppins Light 300 / 14
                    .foregroundStyle(.white.opacity(unread ? 1 : 0.5))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)                   // Figma: text column top/bottom 8

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)                    // Figma: cell inner padding 12
        .frame(minHeight: 72)                        // Figma: cell height 72
        .background(
            unread ? Color.white.opacity(0.05) : Color.clear,  // Figma: unread fill white@5%
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)   // Figma: r=16
        )
        .padding(.horizontal, 8)                     // Figma: cell outer inset 8
        .contentShape(Rectangle())
    }

    /// Customer-side rows show the business logo; business-side rows show a
    /// colored initial tile keyed to the customer so each request is distinct.
    @ViewBuilder
    private var avatar: some View {
        if conversation.viewerIsCustomer {
            ChatBusinessAvatar(logoURL: logoURL, size: 44)   // Figma: 44×44, r=12
        } else {
            InitialAvatar(letter: conversation.avatarInitial,
                          colorSeed: conversation.customerColorSeed ?? conversation.avatarInitial,
                          size: 44)
        }
    }
}

/// A colored tile with the counterparty's initial. Used business-side in the
/// inbox, where every request would otherwise share the same generic avatar.
/// `letter` is the customer's email initial; `colorSeed` (their user id) picks a
/// stable tile color so the same customer always gets the same tile.
struct InitialAvatar: View {
    let letter: String
    let colorSeed: String
    var size: CGFloat = 44

    // Muted tiles that keep white text legible; picked by a stable hash of the seed.
    private static let palette: [Color] = [
        Color(hex: "#E8683C"), Color(hex: "#3C8CE8"), Color(hex: "#4CAF72"),
        Color(hex: "#B65CD1"), Color(hex: "#E0A93C"), Color(hex: "#3CB7C4"),
        Color(hex: "#D1525C"), Color(hex: "#6C74E0"),
    ]

    private var color: Color {
        let sum = colorSeed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(.custom("Lato-Bold", size: size * 0.42))
                    .foregroundStyle(.white)
            )
    }
}

/// The business's avatar in chat — its hosted logo on a white chip when one is
/// resolved (see [[LogoService]]), otherwise the generic business icon on a
/// gray20 tile (Figma "Icon/Business"). Used by both the inbox row and the
/// thread header so the two stay in step. A hosted logo renders on white so
/// dark/transparent marks stay visible against the app's dark background.
struct ChatBusinessAvatar: View {
    let logoURL: URL?
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color.white.opacity(0.2))              // gray20 tile
            .frame(width: size, height: size)
            .overlay {
                if let logoURL {
                    AsyncImage(url: logoURL) { phase in
                        if case .success(let image) = phase {
                            // Fill the whole tile edge-to-edge (no inset chip), so
                            // the business mark reads as a solid thumbnail.
                            image.resizable().scaledToFill()
                                .frame(width: size, height: size)
                                .background(Color.white)
                                .clipped()
                        } else {
                            businessIcon                 // loading / failed → icon
                        }
                    }
                } else {
                    businessIcon
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }

    private var businessIcon: some View {
        Image("ic_business")                             // Figma: Icon/Business
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.55, height: size * 0.55)
            .foregroundStyle(.white)
    }
}
