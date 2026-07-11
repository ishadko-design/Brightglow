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

    // Bubble gradients — Figma node 783:2127, exact stops + handle directions.
    /// Sent (mine): #0039F5 → #3959C5, top-right → bottom-left.
    static let sentGradient = LinearGradient(
        stops: [.init(color: Color(hex: "#0039F5"), location: 0),
                .init(color: Color(hex: "#3959C5"), location: 1)],
        startPoint: UnitPoint(x: 1.0, y: -0.05),
        endPoint: UnitPoint(x: -0.02, y: 0.74)
    )
    /// Received (business message): #2D3047 → #3D2C00, bottom-right → top-left.
    /// Shares the exact stops with the clarify chat's AI follow-up bubble
    /// (MainScreen.chatBubble) so both non-user bubbles read as one system.
    static let receivedGradient = LinearGradient(
        stops: [.init(color: Color(hex: "#2D3047"), location: 0),
                .init(color: Color(hex: "#3D2C00"), location: 1)],
        startPoint: UnitPoint(x: 1.0, y: 0.86),
        endPoint: UnitPoint(x: 0.03, y: 0.0)
    )

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
            // Mark read on the way out too, so replies that arrived while the
            // thread was open are covered (start() only stamps the open time).
            ChatService.markThreadRead(conversation.id)
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
                    .font(.h2)                       // Figma: Lato ExtraBold 800 / 24
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let city = conversation.city, !city.isEmpty {
                    Text(city)
                        .font(.bodySmall)            // Figma: Poppins Light 300 / 14
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The photo belongs to the request, so it hangs off the customer's first
    /// message (direction "outbound") — that's the message it was shared with.
    private var photoAnchorId: UUID? {
        messages.first(where: { $0.direction == "outbound" })?.id
    }

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {            // Figma: 16 between message blocks
                    if loading {
                        ProgressView().tint(.white).padding(.top, 24)
                    }

                    // Fallback: a photo with no message to anchor it to (rare)
                    // still shows on the customer's side.
                    if let photo, photoAnchorId == nil {
                        photoAttachment(photo).padding(.horizontal, 16)
                    }

                    ForEach(messages) { message in
                        // Group the shared photo with the message it came in on,
                        // so it reads as one thing the customer sent.
                        VStack(spacing: 8) {
                            bubble(message)
                            if message.id == photoAnchorId, let photo {
                                photoAttachment(photo)
                            }
                        }
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
                .font(.bodyLight)                    // Figma: Poppins Light 300 / 17
                .foregroundStyle(.white)
                .padding(16)                          // Figma: 16 on all sides
                .background(
                    mine
                        ? AnyShapeStyle(Self.sentGradient)
                        : AnyShapeStyle(Self.receivedGradient),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)  // Figma: r=24
                )
            if !mine { Spacer(minLength: 48) }
        }
    }

    /// The shared request photo, aligned to the customer's side (right for the
    /// customer, left for the business) and rounded to match the bubbles.
    /// `scaledToFit` keeps the whole image — the drawn-on annotation matters.
    private func photoAttachment(_ image: UIImage) -> some View {
        HStack(spacing: 0) {
            if isCustomer { Spacer(minLength: 48) }
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))  // Figma: r=16
            if !isCustomer { Spacer(minLength: 48) }
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
        ChatService.markThreadRead(conversation.id)   // opening = reviewed
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
