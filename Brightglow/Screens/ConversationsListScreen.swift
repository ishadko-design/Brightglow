import SwiftUI

/// The user's inbox — every request they've sent (and, if they're also a
/// business, every request they've received) as a tappable conversation.
/// Reached from the header chat icon on the main screen.
struct ConversationsListScreen: View {
    @Environment(\.dismiss) private var dismiss

    @State private var conversations: [Conversation] = []
    @State private var unreadIDs: Set<UUID> = []
    @State private var loading = true
    @State private var loadError = false

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
        .task { await load() }
        // Fires again when a thread is popped — a reviewed conversation is now
        // read, so recompute which rows still show the unread dot.
        .onAppear { refreshUnread() }
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
                VStack(spacing: 12) {
                    Text("Couldn't load your messages.")
                        .font(.bodyLight)
                        .foregroundStyle(.white.opacity(0.7))
                    Button("Try again") { Task { await load() } }
                        .font(.bodySmall)
                        .foregroundStyle(AppColors.accentStart)
                }
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
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {             // Figma node 783:2224: 4 between cells
                    ForEach(conversations) { convo in
                        NavigationLink {
                            ChatThreadScreen(conversation: convo)
                        } label: {
                            ConversationRow(conversation: convo,
                                            unread: unreadIDs.contains(convo.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }

    private func load() async {
        loadError = false
        do {
            conversations = try await ChatService.conversations()
            refreshUnread()
            loading = false
        } catch {
            loading = false
            loadError = true
        }
    }

    /// Recompute the unread set from the (local) per-thread read timestamps.
    private func refreshUnread() {
        unreadIDs = Set(conversations.filter(ChatService.isUnread).map(\.id))
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

    var body: some View {
        HStack(spacing: 12) {                        // Figma: gap 12
            RoundedRectangle(cornerRadius: 12, style: .continuous)  // Figma: 44×44, r=12
                .fill(AppColors.searchBg)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.7))
                )

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

            if unread {
                Circle()                             // Figma: 12×12 badge, #D4A600
                    .fill(AppColors.starFilled)
                    .frame(width: 12, height: 12)
            }
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
}
