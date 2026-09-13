import SwiftUI
import PhotosUI
import Supabase
import MessageUI

/// Consent / review step before a request is sent to a contractor. Figma node
/// 646:12952 ("Confirmation screen"): contractor avatar + reassurance line,
/// the user's attached photos (a horizontally scrolling strip once there are
/// enough to overflow, centered otherwise), the request text as an editable
/// pill, and a legal disclaimer above the send CTA.
///
/// Sends via LeadBridge (leadbridge/ — separate relay service). contractorEmail
/// is hardcoded to the Brightglow test inbox for now: real contractor-email
/// sourcing (business_enrichment) isn't built yet, so this can't reach an
/// actual business email. Photos are optional — a described request alone is
/// enough to send.
struct QuoteRequestScreen: View {
    var contractor: Contractor? = nil
    /// Photos already captured earlier in the flow (camera + drawing, or the
    /// search bar's own picker) — shown up front so the user reviews exactly
    /// what's about to be sent, rather than picking again from scratch.
    var initialImages: [UIImage] = []
    /// "Motorcycle" or "Car" for an Auto & moto request, empty for home. The
    /// pricing engine already separates the two, but the business only learns
    /// which vehicle from the message text — a shop that services both would
    /// otherwise prep for the wrong one. Prepended to the description sent.
    var vehicleNote: String = ""
    /// The clarifying Q&A captured on the landing (user's request + the chat's
    /// answers), threaded through the results and gallery. The pill below is
    /// pre-filled from it — the business needs the real job details, not an
    /// empty box — but stays fully editable: the user can trim or rewrite
    /// before sending.
    var clarifyTranscript: ClarifyTranscript = .empty

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService

    @State private var email: String = ""
    @State private var editableRequest: String = ""
    @State private var editingEmail = false
    @State private var sent = false
    @State private var sending = false
    @State private var sendError: String? = nil
    #if DEBUG
    /// Test-mode switch (debug builds only): when ON, the lead files under the
    /// dedicated Bright Test Plumbing business instead of the real contractor.
    /// Persists across rebuilds. Release builds always use the real business.
    @AppStorage("debugTestMode") private var debugTestMode = true
    #endif
    // P2P text composer (the primary delivery — the user sends the photo from
    // their own Messages app; see sendRequest). The whole payload is built at
    // send time and presented via `.sheet(item:)`, NOT read from separate @State
    // at content-eval time: the latter can hand MFMessageComposeViewController a
    // stale/empty `body` (makeUIViewController runs once and never re-reads),
    // which is exactly a pre-fill-came-up-blank bug.
    @State private var compose: ComposePayload? = nil

    /// Everything the SMS composer + its completion need, captured atomically when
    /// the user taps Send so the composer is always built from fresh, complete data.
    struct ComposePayload: Identifiable {
        let id = UUID()
        let recipient: String
        let body: String
        /// ALL attached photos — the MMS carries every one (unlike the email
        /// record leg, which LeadBridge caps at one).
        let photos: [UIImage]
        /// ALL attached photos uploaded to the lead record (shown on the /l page
        /// and in the in-app chat) — every one, watermarked.
        let uploadPhotos: [UIImage]
        /// Pure request text (no reply link) for the email/record leg on a send.
        let description: String
        /// App-minted lead id embedded in `body`'s reply link; reused when the
        /// record is created on a real send so `/l/<id>` resolves.
        let publicId: String
    }
    // ⚠️ TEST OVERRIDE — while testing, set this to YOUR OWN number so every P2P
    // text routes to you instead of the real business. Empty string = text the
    // real business. MUST be "" before shipping. (Email is already safe via
    // EMAIL_OVERRIDE_TO on the backend.)
    private static let smsTestRecipient = ""   // e.g. "+15551234567"
    @State private var images: [UIImage] = []
    /// The business's hosted logo, resolved once on appear (LogoService). Only a
    /// real, resolved logo is ever shown — there's deliberately no monogram
    /// fallback here (an initials tile reads as a fake mark on a screen that's all
    /// about "this is who your request goes to").
    @State private var logoURL: URL? = nil
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
    /// Send needs the user's own words — a request that's just a category name
    /// (or nothing) tells the business nothing actionable. A photo helps but
    /// isn't required.
    private var hasDescription: Bool {
        !editableRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Whether THIS device can actually present the SMS composer. `canSendText()`
    /// reports true on the Simulator, but the composer is backed by a remote view
    /// service that doesn't exist there — presenting it terminates the app (the
    /// RunningBoard "Client not entitled" teardown). So force the email fallback in
    /// the Simulator; real devices are unaffected.
    private static var deviceCanText: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return MFMessageComposeViewController.canSendText()
        #endif
    }
    /// True when the request will go out as a person-to-person text (contractor
    /// has a phone and the device can text). On this path the user's own Messages
    /// app is the reply channel — the business gets the customer's number — so no
    /// email is needed or used. Email is only the reply channel on the fallback.
    private var willText: Bool {
        contractor?.phone != nil && Self.deviceCanText
    }
    private var canSend: Bool {
        (willText || emailValid) && hasDescription && contractor != nil && !sending
    }

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
            // Pre-fill the description from the clarify transcript: the user's
            // own request plus the answers they gave (or the chat's overview).
            // An empty pill meant the business got nothing but a photo — and the
            // request text is what they're paying for. Still fully editable;
            // when there's no transcript this stays empty and the user types.
            if editableRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editableRequest = clarifyTranscript.augmentedDescription(base: "")
            }
            if images.isEmpty { images = initialImages }
            resolveLogo()
            AnalyticsService.track("quote_opened", ["place_id": contractor?.id ?? ""])
        }
    }

    // MARK: - Review / consent

    /// Sticky send footer, pinned to the bottom safe-area inset. Its background
    /// fades from clear into the page colour so the content scrolls smoothly
    /// underneath it.
    private var sendFooter: some View {
        VStack(spacing: 16) {
            Text("We'll open your Messages app, just tap send there to finish. Msg & data rates may apply")
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            Button(action: sendRequest) {
                if sending {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                } else {
                    Text("Continue")
                        .font(.h3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
            }
            .buttonStyle(.gradient)
            .disabled(!canSend)

            // Consent folded into the action: tapping Continue is the agreement.
            // Markdown link opens the Business Terms. The customer is soliciting
            // contact, so this reply consent isn't marketing consent.
            Text("By tapping Continue, you agree to the [Terms](https://brightglow.co/terms.html) and to let this business contact you.")
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.6))
                .tint(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 32)
        .background(
            LinearGradient(
                stops: [
                    .init(color: AppColors.bg.opacity(0),    location: 0.0),
                    .init(color: AppColors.bg.opacity(0.85), location: 0.10),
                    .init(color: AppColors.bg,               location: 0.20),
                    .init(color: AppColors.bg,               location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

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
                Text("Send your request to")
                    .font(.h2)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.top, 8)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 44) {

                    // Who the request goes to — the business's real logo (when one
                    // resolves) above its name. (Figma node 1336:5866.)
                    businessHeader
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        // Breathing room under the title so the smaller logo isn't
                        // crammed against the top of the scroll area.
                        .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 24) {
                        // Photos — optional. A horizontally scrolling strip once
                        // there's more than fits; centered when there's just a
                        // photo or two (or only the add tile).
                        photosSection

                        // The full outgoing message as an editable preview pill:
                        // request + folded-in details + the "Sent via Brightglow"
                        // attribution the business receives.
                        requestPill
                            .id("requestPill")

                        // Collect the reply email inline ONLY on the email-only
                        // fallback (no phone / can't text), where it's the sole way
                        // the business can reach the customer. On the text path the
                        // user's own Messages app carries their number, so the email
                        // is unused — asking for it there is pointless friction and
                        // wrongly blocks send (see willText / canSend).
                        if !willText && !emailValid {
                            emailFixCard
                        }


                        if let sendError {
                            warning(sendError)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 8)
            }
            // Let the user swipe the keyboard back down while editing.
            .scrollDismissesKeyboard(.interactively)
            // When editing starts, lift the request pill to just under the header so
            // the user sees what they type (the keyboard covers the lower half).
            .onChange(of: requestFocused) { _, focused in
                if focused {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("requestPill", anchor: .top)
                    }
                }
            }
            // The send footer pins to the bottom safe-area inset, so the scroll
            // content insets by the footer's real height — the last line can
            // always scroll fully above it (no magic-number bottom padding).
            .safeAreaInset(edge: .bottom, spacing: 0) { sendFooter }
            }
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
                    // Photos are added as attachments only — the drawing tool
                    // opens only when the user taps a thumbnail. Auto-opening
                    // it on add wiped the request text field (full-screen
                    // cover cycle resets the TextField state).
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
                    // No auto-description in the annotation editor — the photo was
                    // already described at capture time.
                    autoDescription: .constant(""),
                    // Draw-only: the request is already written on the send screen, so
                    // "Edit" is purely for circling — hide the text input entirely.
                    showsTextInput: false,
                    paths: $drawingPaths
                )
            }
        }
        // Primary delivery: the user texts the photo + request to the business
        // from their OWN Messages app (person-to-person MMS). Carries the picture
        // a phone call can't, with zero A2P/10DLC/TCPA exposure. Email goes as a
        // duplicate in the background (see sendRequest).
        .sheet(item: $compose) { payload in
            MessageComposerView(recipient: payload.recipient, body: payload.body, photos: payload.photos) { result in
                compose = nil
                // The blue Send INSIDE Messages: the true conversion. .sent means
                // the text actually went; .cancelled is the abandon we couldn't
                // see before; .failed is a compose error.
                AnalyticsService.track("send_result", [
                    "place_id": contractor?.id ?? "",
                    "channel": "text",
                    "outcome": result == .sent ? "sent" : (result == .failed ? "failed" : "cancelled"),
                ])
                // Only a real send delivers anything. Cancelling (or a compose
                // failure) leaves the business with nothing and keeps the user on
                // the form — no email leg, no "Request sent".
                guard result == .sent else {
                    if result == .failed { sendError = "Couldn't open Messages. Try again." }
                    return
                }
                // The text went — record the lead with the SAME id used in the
                // reply link (so /l/<id> resolves), but notify:false: the user's
                // own text is the delivery, so LeadBridge sends no email here.
                // Awaited, not fire-and-forget: if the lead isn't recorded the
                // reply link 404s, so "Request sent" waits for the save. A
                // failure surfaces as an error instead of vanishing into try?.
                if let contractor {
                    Task {
                        do {
                            try await submitEmailLead(contractor, description: payload.description, photos: payload.uploadPhotos,
                                                      publicId: payload.publicId, notify: false)
                            await MainActor.run {
                                withAnimation(.easeInOut(duration: 0.25)) { sent = true }
                            }
                        } catch {
                            await MainActor.run {
                                sendError = "Text sent, but the request link couldn't be saved. Please try again."
                            }
                        }
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) { sent = true }
                }
            }
            .ignoresSafeArea()
        }
    }

    /// The recipient block under the "Send your request to" header: the business's
    /// real logo (only when one resolves — no monogram/initials fallback) above its
    /// name. Name in Poppins Light 17, centered; 24pt gap. The logo is 44×44 (r12) —
    /// half the Figma's 88, since resolved marks are often small/low-res and blow up
    /// badly at full size; smaller keeps a pixelated logo from dominating the screen.
    private var businessHeader: some View {
        VStack(spacing: 24) {
            if let logoURL {
                AsyncImage(url: logoURL) { phase in
                    if case .success(let image) = phase {
                        // On a white backing so dark/transparent marks stay visible
                        // against the dark UI, matching the list-row logo chip.
                        image.resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    // No fallback tile: if the resolved logo can't load, the name
                    // alone carries the screen rather than a placeholder square.
                }
                .frame(width: 44, height: 44)
            }
            Text(contractor?.name ?? "this business")
                .font(.bodyLight)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
    }

    /// Resolve this business's hosted logo once (best-effort). A miss leaves
    /// `logoURL` nil and the header simply shows no avatar.
    private func resolveLogo() {
        guard logoURL == nil, let contractor, contractor.website != nil else { return }
        Task {
            let found = await LogoService.fetch(for: [contractor])
            await MainActor.run { logoURL = found[contractor.id] }
        }
    }

    // MARK: - Photos

    private var photosSection: some View {
        // Figma tiles are 112×136 (portrait). A centered strip when every tile
        // fits the available width; otherwise a scrolling strip. ViewThatFits
        // measures for us — no UIScreen.main (deprecated in iOS 26).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tiles(width: 112, height: 136)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tiles(width: 112, height: 136)
                }
            }
        }
        .frame(maxWidth: .infinity)
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

            // Edit (pencil) — bottom-leading, inset inside the tile. Frosted
            // secondary-button background (Capsule on a square = circle).
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .secondaryButtonBackground()
                .padding(8)
                .frame(width: width, height: height, alignment: .bottomLeading)
                .allowsHitTesting(false)

            // Remove (✕) — top-trailing, inset inside the tile (not offset out).
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { _ = images.remove(at: index) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .secondaryButtonBackground()
            }
            .padding(8)
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

    // The full outgoing message as an editable preview. Uses the app's single
    // text-field treatment (bgSecondary fill, 1.5pt gray20 border, r32 — the same
    // `inputFieldSurface` the business dashboard uses) so every input reads as one
    // product. The message text is editable in place. (Adding a photo is handled by
    // the add tile above — no redundant "+" in the field.)
    private var requestPill: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Describe your request…", text: $editableRequest, axis: .vertical)
                .font(.bodyLight)
                .foregroundStyle(.white)
                .tint(AppColors.accentStart)
                .focused($requestFocused)
                .submitLabel(.done)
                .lineLimit(1...14)
                .onSubmit { requestFocused = false }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A multiline field can't submit on Return (it inserts a newline),
                // so give the keyboard an explicit Done to fold it back down.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { requestFocused = false }
                    }
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgOverlay, in: shape)
        .overlay(shape.stroke(AppColors.searchBorder, lineWidth: 1.5))
    }

    // MARK: - Email (only surfaced when it needs fixing)

    private var emailFixCard: some View {
        labeledCard(title: "Where we can reach you") {
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
                warning("Apple's private relay address can't receive replies. Add a direct email.")
            } else if !email.isEmpty && !emailValid {
                warning("That doesn't look like a valid email.")
            }
        }
    }

    // MARK: - Sent confirmation

    private var sentState: some View {
        VStack(spacing: 0) {
            // Header: back + "Request sent". (The "Send to top 5" pill in the
            // node is a hidden layer — visible=false — so it stays out.)
            HStack(spacing: 4) {
                Button(action: { dismiss() }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Text("Request sent")
                    .font(.h2)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 44)

            // Illustration: 206×202 paper-plane artwork, centered in its
            // 220-tall slot (Figma "Sent message-il").
            Image("fig_request_sent")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 206, height: 202)
                .frame(height: 220)
                .padding(.top, 106)

            // Title + body.
            VStack(spacing: 16) {
                Text("Request sent")
                    .font(.h2)
                    .foregroundStyle(.white)
                Text("\(contractor?.name ?? "The business") has your request. They'll reply to you directly.")
                    .font(.bodyLight)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)

            // Done pill.
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .frame(height: 48)
            }
            .background(AppColors.ctaBlue)
            .clipShape(Capsule())
            .padding(.top, 32)

            Spacer()
        }
    }

    // MARK: - Pieces

    private func labeledCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.6))
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
    /// With none attached the lead goes as text only.
    private func sendRequest() {
        guard canSend, let contractor else { return }
#if DEBUG
        // Test-mode indicator: when smsTestRecipient is empty, the composer
        // opens addressed to the business's real number — change it to your
        // own number in the Messages app before sending. The lead will file
        // under the real business name; delete it after testing.
        if Self.smsTestRecipient.isEmpty {
            sendError = "Test mode off: change the recipient to your own number in the Messages app."
        }
#endif
        // The in-app "Send" CTA was tapped — this OPENS the composer; it does not
        // yet deliver. The matching `send_result` event records whether the user
        // then actually sent (the gap between the two is the funnel drop).
        AnalyticsService.track("send_tapped", [
            "place_id": contractor.id,
            "channel": (contractor.phone != nil && Self.deviceCanText) ? "text" : "email",
        ])
        // Watermark the copy that leaves the app: the LeadBridge record photo (shown
        // on the /l/<id> reply page) and the email-leg attachment. The MMS copies get
        // the same mark in the composer's attach loop. On-screen previews stay clean.
        // Watermark EVERY attached photo — all of them are uploaded to the lead
        // record and shown on the /l page + in-app chat (the MMS still carries none).
        let photos = images.map { $0.brightglowWatermarked() }
        emailFocused = false
        requestFocused = false
        editingEmail = false
        sendError = nil

        // The description is what sits in the pill — pre-filled from the clarify
        // transcript (the user's own request + answers), editable in place.
        // The vehicle is named up front for auto/moto so the shop knows which it is.
        let base = editableRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = vehicleNote.isEmpty ? base : "Vehicle: \(vehicleNote)\n\n\(base)"

        if let phone = contractor.phone, Self.deviceCanText {
            // Primary: person-to-person text with the photo, composed in the
            // user's own Messages app. The lead record is NOT created here — it
            // fires from the composer's completion ONLY when the user actually
            // sends, so cancelling delivers nothing and shows no success.
            //
            // Mint the lead id up front so the reply link can go in the message
            // body: it points at a page that shows the photo and lets the business
            // reply into the in-app chat — the fallback for when MMS strips the
            // attachment, and the bridge that keeps the conversation on Brightglow.
            let publicId = LeadBridgeService.newPublicID()
            // Always the same generic text: the job details and photo live behind
            // the /l link, never in the SMS. The link opens a read-only detail page
            // while the business is on its free leads, and the paywall teaser once
            // it's over — so the lead's value is gated on the link, not the message.
            // The photo is still uploaded to the server (payload.photo) so it shows
            // on that page; it's just not attached to the MMS.
            let body = "Hi — I found you on Brightglow and I'd like a quote. "
                + "The details and a photo are here: \(LeadBridgeService.replyURL(publicId: publicId))"
            compose = ComposePayload(
                recipient: Self.smsTestRecipient.isEmpty ? phone : Self.smsTestRecipient,
                body: body,
                photos: [],
                uploadPhotos: photos,
                description: description,
                publicId: publicId
            )
        } else {
            // No phone or the device can't text (e.g. iPad without iMessage) —
            // email is the only channel, so await it and surface any failure.
            sending = true
            Task {
                do {
                    try await submitEmailLead(contractor, description: description, photos: photos)
                    await MainActor.run {
                        sending = false
                        AnalyticsService.track("send_result", ["place_id": contractor.id, "channel": "email", "outcome": "sent"])
                        withAnimation(.easeInOut(duration: 0.25)) { sent = true }
                    }
                } catch {
                    await MainActor.run {
                        sending = false
                        AnalyticsService.track("send_result", ["place_id": contractor.id, "channel": "email", "outcome": "failed"])
                        sendError = "Couldn't send: \(error)"
                    }
                }
            }
        }
    }

    /// Records the lead server-side (chat thread + reply page). With `notify:true`
    /// (no phone) it also emails the business as the delivery channel; with
    /// `notify:false` (P2P text path) it records only — the user's own text is the
    /// delivery and `publicId` matches the id already in that text's reply link.
    private func submitEmailLead(_ contractor: Contractor, description: String, photos: [UIImage],
                                 publicId: String? = nil, notify: Bool = true) async throws {
        let consent = true   // tapping Continue is the agreement (see the footer disclosure)
        // Test mode (smsTestRecipient set — local test builds only): the SMS
        // already goes to the test number, so the lead record must follow it.
        // Without this the record keeps the selected REAL business's identity
        // and test traffic leaks onto real businesses. Rewrite to the dedicated
        // test business (values match the Bright Test Plumbing record).
        #if DEBUG
        let testMode = debugTestMode || !Self.smsTestRecipient.isEmpty
        #else
        let testMode = !Self.smsTestRecipient.isEmpty
        #endif
        _ = try await LeadBridgeService.submitLead(
            userEmail: email,
            userId: auth.user?.id,
            contractorEmail: testMode ? "seed-phone-test@brightglow.co" : (contractor.contactEmail ?? "hello@brightglow.co"),
            businessName: testMode ? "Bright Test Plumbing" : contractor.name,
            // Carried so the chat can show this business's logo as the
            // conversation avatar (id = Places place_id; website resolves it).
            placeId: testMode ? "seed_phone_test_place" : contractor.id,
            website: testMode ? nil : contractor.website,
            // The number the user is texting — the key the business later claims by.
            contractorPhone: testMode ? "+16282029214" : contractor.phone,
            description: description,
            city: contractor.city,
            photos: photos,
            publicId: publicId,
            notify: notify,
            contactConsent: consent
        )
    }
}

/// Wraps the system SMS/MMS composer so the user can send the request — with the
/// photo attached — to the business from their own phone. Person-to-person, so
/// no A2P registration or TCPA exposure; the user taps Send.
struct MessageComposerView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    let photos: [UIImage]
    let onFinish: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        // tel: URLs need bare digits; the composer wants the same.
        vc.recipients = [recipient.filter { $0.isNumber || $0 == "+" }]
        vc.body = body
        // Attach EVERY photo the user added, not just the first.
        var attached = 0
        if MFMessageComposeViewController.canSendAttachments() {
            for (i, image) in photos.enumerated() {
                guard let data = image.brightglowWatermarked().jpegData(compressionQuality: 0.8) else { continue }
                if vc.addAttachmentData(data, typeIdentifier: "public.jpeg", filename: "request-\(i + 1).jpg") {
                    attached += 1
                }
            }
        }
        print("📨 MMS compose → body.count=\(body.count) recipient=\(vc.recipients ?? []) photos=\(photos.count) attached=\(attached)")
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }


    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(result)
        }
    }
}

extension UIImage {
    /// Returns a copy with a small "Sent via Brightglow" mark in the bottom-right
    /// corner. This is the ONE piece of product attribution the customer
    /// can't strip in Messages (unlike a body line) — it travels with the MMS attachment itself,
    /// and points a curious business straight at the site. Applied only to the
    /// outgoing copy at send time, never to the on-screen preview, so the user
    /// reviews their own unaltered photo.
    func brightglowWatermarked() -> UIImage {
        // Downscale huge photos FIRST. A 32MP shot (e.g. 3870×8388) renders into a
        // ~130MB bitmap, and we do this twice per send (attachment + record copy) —
        // enough to get the app jetsam-killed on a real device. An MMS/email photo
        // never needs more than ~2048px on its long side, so cap it there. Also pin
        // the renderer scale to 1 so it doesn't silently multiply by the screen
        // scale (2×/3×) and quadruple the memory again.
        let maxDim: CGFloat = 2048
        let longest = max(size.width, size.height)
        let scaleDown = longest > maxDim ? maxDim / longest : 1
        let target = CGSize(width: (size.width * scaleDown).rounded(),
                            height: (size.height * scaleDown).rounded())

        // A clean "Sent via Brightglow" signature baked into the photo — brand only,
        // no URL clutter. It travels with the image so the sender can't strip it, and
        // reads as attribution, NOT an ad, so it doesn't make the business think this
        // is an automated blast they can't just reply to. The tappable URL lives in
        // the message body footer ("Sent via brightglow.co/biz").
        let text = "Sent via Brightglow"
        // Scale the mark to the (final) image so it reads the same on a tiny
        // thumbnail or a full-res shot; clamp so it never disappears on small images.
        let fontSize = max(target.width * 0.03, 14)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pad = fontSize * 0.7

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { ctx in
            draw(in: CGRect(origin: .zero, size: target))
            // A soft dark shadow keeps white legible over light subjects (tile,
            // porcelain, a white vanity) without a visible plate.
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1),
                                    blur: fontSize * 0.5,
                                    color: UIColor.black.withAlphaComponent(0.55).cgColor)
            let origin = CGPoint(x: target.width - textSize.width - pad,
                                 y: target.height - textSize.height - pad)
            (text as NSString).draw(at: origin, withAttributes: attrs)
        }
    }
}
