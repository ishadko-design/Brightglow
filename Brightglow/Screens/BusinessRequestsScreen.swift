import SwiftUI

/// The business's requests, reached from the Leads / Requests tiles on the
/// dashboard (Figma 1096:5241 keeps the dashboard itself to tiles + readiness —
/// the list lives here, one level down).
///
/// Deep links still land straight in a thread via the dashboard; this screen is
/// the browse path, so it only needs the list and a way back.
struct BusinessRequestsScreen: View {
    @EnvironmentObject private var store: BusinessStore
    @Environment(\.dismiss) private var dismiss

    @State private var openConvoID: UUID? = nil

    private var leads: [Conversation] { store.selected?.leads ?? [] }

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .preferredColorScheme(.dark)
        .navigationDestination(item: $openConvoID) { id in
            if let convo = leads.first(where: { $0.id == id }) {
                ChatThreadScreen(conversation: convo)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Text("Requests")
                .font(.h2)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if leads.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 36)).foregroundStyle(.white.opacity(0.3))
                Text("No requests yet")
                    .font(.h4).foregroundStyle(.white)
                Text("New customer requests matched to your business show up here.")
                    .font(.bodySmall).foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 40)
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(leads) { lead in
                        Button { openConvoID = lead.id } label: {
                            BusinessRequestRow(conversation: lead)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

/// One request in the list — the last message, a relative time, and a "Reply
/// needed" pill when the customer is waiting on the business.
struct BusinessRequestRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            ChatBusinessAvatar(logoURL: nil, size: 44)   // customer side: generic icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(conversation.city?.isEmpty == false ? conversation.city! : "New request")
                        .font(.custom("Lato-Bold", size: 17))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    if conversation.lastMessageIncoming {
                        Text("Reply needed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppColors.bg)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(AppColors.starFilled, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if let at = conversation.lastMessageAt {
                        Text(at, format: .relative(presentation: .named))
                            .font(.bodySmall).foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
                Text(conversation.lastMessage ?? "New request — no messages yet")
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(conversation.lastMessageIncoming ? 1 : 0.5))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 72)
        .background(
            conversation.lastMessageIncoming ? AppColors.cardSurface : Color.clear,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
