import SwiftUI
import PhotosUI
import Supabase

/// Consent / review step before a request is sent to a contractor. Figma node
/// 646:12952 ("Confirmation screen"): contractor avatar + reassurance line,
/// the user's attached photos (a horizontally scrolling strip once there are
/// enough to overflow, centered otherwise), the request text as an editable
/// pill, and a legal disclaimer above the send CTA.
///
/// Sends via LeadBridge (leadbridge/ — separate relay service). contractorEmail
/// is hardcoded to the Brightglow test inbox for now: real contractor-email
/// sourcing (business_enrichment) isn't built yet, so this can't reach an
/// actual business email. A photo is required — LeadBridge's design is
/// photo + text, not text alone.
struct QuoteRequestScreen: View {
    var contractor: Contractor? = nil
    var requestSummary: String = ""
    /// Photos already captured earlier in the flow (camera + drawing, or the
    /// search bar's own picker) — shown up front so the user reviews exactly
    /// what's about to be sent, rather than picking again from scratch.
    var initialImages: [UIImage] = []

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService

    @State private var email: String = ""
    @State private var editableRequest: String = ""
    @State private var editingEmail = false
    @State private var sent = false
    @State private var sending = false
    @State private var sendError: String? = nil
    @State private var images: [UIImage] = []
    @State private var pickedItems: [PhotosPickerItem] = []
    /// Index into `images` currently open in the drawing view — set by tapping a
    /// photo, so the user can circle something as an afterthought.
    @State private var drawingIndex: Int? = nil
    @State private var drawingPaths: [DrawnPath] = []
    @FocusState private var emailFocused: Bool
    @FocusState private var requestFocused: Bool

    private var isRelay: Bool { email.localizedCaseInsensitiveContains("privaterelay.appleid.com") }
    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.contains("@") && e.contains(".") && !e.hasSuffix("@") && !isRelay
    }
    /// Shown only when the signed-in email needs attention — the screen has no
    /// email card in the normal case (Figma doesn't show one; it's collected
    /// at sign-in), so this only ever surfaces to unblock a broken send.
    private var emailNeedsAttention: Bool { !email.isEmpty && !emailValid }
    private var canSend: Bool { emailValid && !images.isEmpty && contractor != nil && !sending }

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            if sent { sentState } else { reviewState }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .preferredColorScheme(.dark)
        .onAppear {
            if email.isEmpty { email = auth.user?.email ?? "" }
            if editableRequest.isEmpty { editableRequest = requestSummary }
            if images.isEmpty { images = initialImages }
        }
    }

    // MARK: - Review / consent

    private var reviewState: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Back — same as every other header: plain arrow, no circle.
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Text("Send your request")
                    .font(.h2)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 24) {

                    // Contractor avatar + reassurance line — centered.
                    VStack(spacing: 24) {
                        contractorAvatar
                        reassuranceText
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)

                    VStack(alignment: .leading, spacing: 24) {
                        // Photos — required by LeadBridge (photo + text, not text alone).
                        // A horizontally scrolling strip once there's more than fits;
                        // centered when there's just a photo or two.
                        photosSection

                        // Request text — editable pill, matches the app's input-bar
                        // styling (leading icon, dark frosted background).
                        requestPill

                        Text("By sending, you agree to share your request and photos with \(contractor?.name ?? "this business"), and to Brightglow's Terms of Service.")
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.6))

                        if emailNeedsAttention {
                            emailFixCard
                        }

                        if let sendError {
                            warning(sendError)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            // Send
            Button(action: sendRequest) {
                if sending {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                } else {
                    Text("Send request")
                        .font(.h3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
            }
            .buttonStyle(.gradient)
            .disabled(!canSend)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var added: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        added.append(img)
                    }
                }
                await MainActor.run {
                    images.append(contentsOf: added)
                    pickedItems = []
                }
            }
        }
        // Tapping a photo opens the same drawing tool used at capture time, so
        // the user can circle something as an afterthought before sending.
        .fullScreenCover(isPresented: Binding(
            get: { drawingIndex != nil },
            set: { if !$0 { drawingIndex = nil } }
        )) {
            if let index = drawingIndex, images.indices.contains(index) {
                DrawModeView(
                    image: images[index],
                    onBack: {
                        drawingPaths = []
                        drawingIndex = nil
                    },
                    onSubmit: { _, resultImage in
                        images[index] = resultImage
                        drawingPaths = []
                        drawingIndex = nil
                    },
                    paths: $drawingPaths
                )
            }
        }
    }

    // MARK: - Contractor avatar

    /// Same initials placeholder used in the contractor list (contractors carry
    /// no logo asset), scaled up to this screen's 88×88 footprint.
    private var contractorAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.12))
            Text(String(contractor?.name.prefix(1) ?? "?"))
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 88, height: 88)
    }

    private var reassuranceText: some View {
        let name = contractor?.name ?? "this business"
        let tail = name.hasSuffix(".") ? " They'll reply to you directly." : ". They'll reply to you directly."
        return (
            Text("We'll email your request to ")
                + Text(name).fontWeight(.bold)
                + Text(tail)
        )
        .font(.bodyLight)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
    }

    // MARK: - Photos

    private var photosSection: some View {
        // Figma tiles are 112×136 (portrait). A strip of `tileCount` tiles at
        // that size, centered, if it fits; otherwise a scrolling strip.
        let tileCount = images.count + 1
        let tileWidth: CGFloat = 112
        let tileHeight: CGFloat = 136
        let available = UIScreen.main.bounds.width - 32
        let needed = CGFloat(tileCount) * tileWidth + CGFloat(tileCount - 1) * 8

        return Group {
            if needed <= available {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    tiles(width: tileWidth, height: tileHeight)
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        tiles(width: tileWidth, height: tileHeight)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tiles(width: CGFloat, height: CGFloat) -> some View {
        ForEach(Array(images.enumerated()), id: \.offset) { index, img in
            photoThumbnail(img, index: index, width: width, height: height)
        }
        addPhotoTile(width: width, height: height)
    }

    private func photoThumbnail(_ img: UIImage, index: Int, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture { drawingIndex = index }

            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.2)))
                .padding(6)
                .frame(width: width, height: height, alignment: .bottomLeading)
                .allowsHitTesting(false)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { _ = images.remove(at: index) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white.opacity(0.2)))
            }
            .offset(x: 6, y: -6)
        }
    }

    private func addPhotoTile(width: CGFloat, height: CGFloat) -> some View {
        PhotosPicker(selection: $pickedItems, matching: .images, photoLibrary: .shared()) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.searchBg)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppColors.border, lineWidth: 1))
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.2)))
            }
            .frame(width: width, height: height)
        }
        .accessibilityLabel(images.isEmpty ? "Add a photo" : "Add another photo")
    }

    // MARK: - Request text

    private var requestPill: some View {
        TextField("Describe your request…", text: $editableRequest, axis: .vertical)
            .font(.bodyLight)
            .foregroundStyle(.white)
            .tint(AppColors.accentStart)
            .focused($requestFocused)
            .submitLabel(.done)
            .lineLimit(1...6)
            .onSubmit { requestFocused = false }
            .padding(16)
            .background {
                ZStack {
                    Color.clear.background(.ultraThinMaterial)
                    AppColors.searchBg
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 32))
            .overlay(RoundedRectangle(cornerRadius: 32).stroke(AppColors.searchBorder, lineWidth: 1.5))
    }

    // MARK: - Email (only surfaced when it needs fixing)

    private var emailFixCard: some View {
        labeledCard(title: "Contractors will reply to you at") {
            if editingEmail {
                TextField("you@email.com", text: $email)
                    .font(.bodyLight)
                    .foregroundStyle(.white)
                    .tint(AppColors.accentStart)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($emailFocused)
                    .submitLabel(.done)
                    .onSubmit { editingEmail = false }
            } else {
                HStack {
                    Text(email.isEmpty ? "Add an email" : email)
                        .font(.bodyLight)
                        .foregroundStyle(email.isEmpty ? .white.opacity(0.4) : .white)
                    Spacer()
                    Button("Edit") {
                        editingEmail = true
                        emailFocused = true
                    }
                    .font(.bodySmall)
                    .foregroundStyle(AppColors.accentStart)
                    .buttonStyle(.textAction)
                }
            }

            if isRelay {
                warning("Apple's private relay address can't receive replies from contractors. Add a direct email.")
            } else if !email.isEmpty && !emailValid {
                warning("That doesn't look like a valid email.")
            }
        }
    }

    // MARK: - Sent confirmation

    private var sentState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(AppColors.accentStart)
            Text("Request sent")
                .font(.h2)
                .foregroundStyle(.white)
            Text("\(contractor?.name ?? "The contractor") will reply to you at \(email).")
                .font(.bodyLight)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .buttonStyle(.gradient)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Pieces

    private func labeledCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppColors.searchBg)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppColors.border, lineWidth: 1))
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.bodySmall)
            .foregroundStyle(AppColors.starFilled)
            .padding(.top, 4)
    }

    /// contractorEmail is hardcoded to the Brightglow test inbox — real
    /// contractor-email sourcing (business_enrichment) isn't built yet, so
    /// this can't reach contractor.name's actual business.
    ///
    /// LeadBridge only accepts one photo per lead — when several are attached,
    /// the first (the drawn/annotated one, when there is one) is what's sent.
    private func sendRequest() {
        guard canSend, let contractor, let photo = images.first else { return }
        emailFocused = false
        requestFocused = false
        editingEmail = false
        sendError = nil
        sending = true

        let description = editableRequest.isEmpty ? requestSummary : editableRequest
        Task {
            do {
                _ = try await LeadBridgeService.submitLead(
                    userEmail: email,
                    contractorEmail: "hello@brightglow.co",
                    businessName: contractor.name,
                    description: description,
                    city: contractor.city,
                    photo: photo
                )
                await MainActor.run {
                    sending = false
                    withAnimation(.easeInOut(duration: 0.25)) { sent = true }
                }
            } catch {
                // Temporarily surfacing the real error (not just a generic
                // message) while diagnosing why sends are failing client-side
                // with nothing landing server-side.
                await MainActor.run {
                    sending = false
                    sendError = "Couldn't send: \(error)"
                }
            }
        }
    }
}
