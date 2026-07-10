import SwiftUI

/// The user's inbox — every request they've sent (and, if they're also a
/// business, every request they've received) as a tappable conversation.
/// Reached from the header chat icon on the main screen.
struct ConversationsListScreen: View {
    @Environment(\.dismiss) private var dismiss

    @State private var conversations: [Conversation] = []
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
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { convo in
                        NavigationLink {
                            ChatThreadScreen(conversation: convo)
                        } label: {
                            ConversationRow(conversation: convo)
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
            loading = false
        } catch {
            loading = false
            loadError = true
        }
    }
}

/// One row in the inbox: title, last message preview, relative time.
private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppColors.searchBg)
                Image(systemName: "hammer.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.title)
                        .font(.h4)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    if let at = conversation.lastMessageAt {
                        Text(at, format: .relative(presentation: .named))
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                Text(conversation.lastMessage ?? "No messages yet")
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
