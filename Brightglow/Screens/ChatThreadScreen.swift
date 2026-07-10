import SwiftUI

/// A single conversation: the request photo up top (once), the message
/// history, and an input bar. New replies arrive live over Realtime; sends go
/// through LeadBridge so the other party is emailed if they're not in the app.
struct ChatThreadScreen: View {
    let conversation: Conversation

    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ConversationMessage] = []
    @State private var photo: UIImage? = nil
    @State private var loading = true
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String? = nil
    @State private var liveTask: Task<Void, Never>? = nil
    @FocusState private var inputFocused: Bool

    private var isCustomer: Bool { conversation.viewerIsCustomer }

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                messageList
                inputBar
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .preferredColorScheme(.dark)
        .task { await start() }
        .onDisappear {
            liveTask?.cancel()
            liveTask = nil
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
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title)
                    .font(.h3)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let city = conversation.city, !city.isEmpty {
                    Text(city)
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 220, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .frame(maxWidth: .infinity, alignment: isCustomer ? .trailing : .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    if loading {
                        ProgressView().tint(.white).padding(.top, 24)
                    }

                    ForEach(messages) { message in
                        bubble(message)
                            .id(message.id)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: messages) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private func bubble(_ message: ConversationMessage) -> some View {
        let mine = message.isFromViewer(customer: isCustomer)
        return HStack {
            if mine { Spacer(minLength: 48) }
            Text(message.body)
                .font(.bodyLight)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    mine
                        ? AnyShapeStyle(AppColors.accentGradient)
                        : AnyShapeStyle(Color.white.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            if !mine { Spacer(minLength: 48) }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let sendError {
                Text(sendError)
                    .font(.bodySmall)
                    .foregroundStyle(AppColors.starFilled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
            HStack(alignment: .center, spacing: 12) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .font(.bodyLight)
                    .foregroundStyle(.white)
                    .tint(AppColors.accentStart)
                    .focused($inputFocused)
                    .lineLimit(1...5)

                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        ZStack {
                            Circle().fill(AppColors.accentGradient)
                            if sending {
                                ProgressView().tint(.white).controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .frame(width: 44, height: 44)
                    .disabled(sending)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    Color.clear.background(.ultraThinMaterial)
                    AppColors.searchBg
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(AppColors.searchBorder, lineWidth: 1.5))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
    }

    // MARK: - Data

    private func start() async {
        await loadMessages()
        loading = false
        loadPhoto()
        subscribe()
    }

    private func loadMessages() async {
        if let loaded = try? await ChatService.messages(leadId: conversation.id) {
            messages = loaded
        }
    }

    private func loadPhoto() {
        guard let attachmentId = conversation.photoAttachmentId else { return }
        Task {
            if let data = try? await LeadBridgeService.fetchAttachment(id: attachmentId),
               let image = UIImage(data: data) {
                await MainActor.run { photo = image }
            }
        }
    }

    /// Live replies: append anything we don't already have (our own sends are
    /// added optimistically, so Realtime echoes are deduped by id).
    private func subscribe() {
        liveTask?.cancel()
        liveTask = Task {
            for await message in ChatService.liveMessages(leadId: conversation.id) {
                await MainActor.run {
                    guard !messages.contains(where: { $0.id == message.id }) else { return }
                    messages.append(message)
                }
            }
        }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        draft = ""
        Task {
            do {
                let created = try await LeadBridgeService.sendMessage(
                    publicId: conversation.publicId,
                    body: body,
                    fromCustomer: isCustomer
                )
                await MainActor.run {
                    sending = false
                    if !messages.contains(where: { $0.id == created.id }) {
                        messages.append(created)
                    }
                }
            } catch {
                await MainActor.run {
                    sending = false
                    draft = body            // restore so the text isn't lost
                    sendError = "Couldn't send. Tap send to try again."
                }
            }
        }
    }
}
