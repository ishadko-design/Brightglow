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
    var requestSummary: String = ""
    /// Photos already captured earlier in the flow (camera + drawing, or the
    /// search bar's own picker) — shown up front so the user reviews exactly
    /// what's about to be sent, rather than picking again from scratch.
    var initialImages: [UIImage] = []
    /// The clarifying Q&A from the landing chat. Its details are woven into the
    /// description sent to the business (an AI-augmented summary), and shown here
    /// read-only so the user sees exactly what's added on top of their own words.
    var clarifyTranscript: ClarifyTranscript = .empty
    /// "Motorcycle" or "Car" for an Auto & moto request, empty for home. The
    /// pricing engine already separates the two, but the business only learns
    /// which vehicle from the message text — a shop that services both would
    /// otherwise prep for the wrong one. Prepended to the description sent.
    var vehicleNote: String = ""

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService

    @State private var email: String = ""
    @State private var editableRequest: String = ""
    @State private var editingEmail = false
    @State private var sent = false
    @State private var sending = false
    @State private var sendError: String? = nil
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
        let photo: UIImage?
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
    /// True when the request will go out as a person-to-person text (contractor
    /// has a phone and the device can text). On this path the user's own Messages
    /// app is the reply channel — the business gets the customer's number — so no
    /// email is needed or used. Email is only the reply channel on the fallback.
    private var willText: Bool {
        contractor?.phone != nil && MFMessageComposeViewController.canSendText()
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
            // Pre-fill with the FULL composed message the business will read —
            // the user's words plus the "Details:" folded in from the clarifying
            // Q&A — so the pill is a true preview (matching the Figma), editable
            // in place. The "Sent via Brightglow" attribution is shown separately
            // and appended at send, so it stays out of the editable text.
            if editableRequest.isEmpty {
                editableRequest = clarifyTranscript.augmentedDescription(base: requestSummary)
            }
            if images.isEmpty { images = initialImages }
            resolveLogo()
            AnalyticsService.track("quote_opened", ["place_id": contractor?.id ?? ""])
        }
    }

    // MARK: - Review / consent

    /// Neutral buyer-side coaching, shown as bullets under the request. Purely
    /// informational — never attached to the outgoing message or sent to a business.
    private let buyerTips: [String] = [
        "Get 3 quotes to compare",
        "Ask for a licence # & insurance",
        "Give each business the same scope",
        "Get the quote in writing",
    ]

    /// Tips list below the request input. Sits at the bottom of the scroll, under
    /// the sticky footer, so it peeks out and the user can scroll to read it.
    private var tipsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tips for comparing quotes", systemImage: "lightbulb")
                .font(.bodySmall)
                .fontWeight(.semibold)
                .foregroundStyle(AppColors.textSecondary)
            ForEach(buyerTips, id: \.self) { tip in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(AppColors.textSecondary)
                    Text(tip)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.bodyLight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sticky send footer, overlaid on the scroll. Its background fades from clear
    /// into the page colour so the tips scroll smoothly underneath it.
    private var sendFooter: some View {
        VStack(spacing: 16) {
            Text("We'll open your Messages app, just tap send there to finish. Msg & data rates may apply")
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.5))
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
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 32)
        .background(
            LinearGradient(
                stops: [
                    .init(color: AppColors.bg.opacity(0), location: 0.0),
                    .init(color: AppColors.bg,            location: 0.35),
                    .init(color: AppColors.bg,            location: 1.0),
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

                    // Buyer tips — bullet points below the request. Informational
                    // only (never sent to the business). They sit beneath the sticky
                    // footer and peek out; the user can scroll to read them all.
                    tipsList
                        .padding(.horizontal, 16)
                }
                .padding(.top, 8)
                // Room to scroll the tips out from under the overlaid footer.
                .padding(.bottom, 160)
            }
            // The send footer overlays the scroll, so the tips slide underneath it.
            .overlay(alignment: .bottom) { sendFooter }
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
                    // A single new photo goes straight to the full-screen drawing
                    // tool so the user can circle the problem right away (same
                    // as tapping its thumbnail); batch-adds skip it.
                    if added.count == 1 { drawingIndex = images.count - 1 }
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
                if let contractor {
                    Task { try? await submitEmailLead(contractor, description: payload.description, photo: payload.photo,
                                                      publicId: payload.publicId, notify: false) }
                }
                withAnimation(.easeInOut(duration: 0.25)) { sent = true }
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
    // product. The message text is editable in place; the attribution line under
    // it is read-only, so the user sees exactly what the business gets. (Adding a
    // photo is handled by the add tile above — no redundant "+" in the field.)
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

            Text("See more jobs like this at brightglow.co/biz")
                .font(.bodyLight)
                .foregroundStyle(.white.opacity(0.5))
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
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(AppColors.accentStart)
            Text("Request sent")
                .font(.h2)
                .foregroundStyle(.white)
            Text("\(contractor?.name ?? "The business") has your request. They'll reply to you directly.")
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
        // The in-app "Send" CTA was tapped — this OPENS the composer; it does not
        // yet deliver. The matching `send_result` event records whether the user
        // then actually sent (the gap between the two is the funnel drop).
        AnalyticsService.track("send_tapped", [
            "place_id": contractor.id,
            "channel": (contractor.phone != nil && MFMessageComposeViewController.canSendText()) ? "text" : "email",
        ])
        // Watermark the copy that leaves the app: the LeadBridge record photo (shown
        // on the /l/<id> reply page) and the email-leg attachment. The MMS copies get
        // the same mark in the composer's attach loop. On-screen previews stay clean.
        let photo = images.first?.brightglowWatermarked()
        emailFocused = false
        requestFocused = false
        editingEmail = false
        sendError = nil

        // editableRequest already IS the composed message — it's pre-filled on
        // appear with the user's words plus the folded-in "Details:" from the Q&A,
        // and edited in place — so use it verbatim rather than augmenting twice.
        // The vehicle is named up front for auto/moto so the shop knows which it is.
        let base = editableRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = vehicleNote.isEmpty ? base : "Vehicle: \(vehicleNote)\n\n\(base)"

        if let phone = contractor.phone, MFMessageComposeViewController.canSendText() {
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
            // Frictionless on a normal lead: the photo's attached to the MMS and the
            // business just replies in Messages — no page to visit. Attribute the
            // source with a value-forward CTA to the claim hub (brightglow.co/biz)
            // where they log in or claim their profile. (The /l/<id> reply link is
            // reserved for the paywall moment — the last/over-quota lead — where the
            // extra tap earns its keep by driving the subscribe.)
            let body = description + "\n\nSee more jobs like this at brightglow.co/biz"
            // One atomic payload → the composer is always built from complete data.
            compose = ComposePayload(
                recipient: Self.smsTestRecipient.isEmpty ? phone : Self.smsTestRecipient,
                body: body,
                photos: images,
                photo: photo,
                description: description,
                publicId: publicId
            )
        } else {
            // No phone or the device can't text (e.g. iPad without iMessage) —
            // email is the only channel, so await it and surface any failure.
            sending = true
            Task {
                do {
                    try await submitEmailLead(contractor, description: description, photo: photo)
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
    private func submitEmailLead(_ contractor: Contractor, description: String, photo: UIImage?,
                                 publicId: String? = nil, notify: Bool = true) async throws {
        _ = try await LeadBridgeService.submitLead(
            userEmail: email,
            userId: auth.user?.id,
            contractorEmail: contractor.contactEmail ?? "hello@brightglow.co",
            businessName: contractor.name,
            // Carried so the chat can show this business's logo as the
            // conversation avatar (id = Places place_id; website resolves it).
            placeId: contractor.id,
            website: contractor.website,
            // The number the user is texting — the key the business later claims by.
            contractorPhone: contractor.phone,
            description: description,
            city: contractor.city,
            photo: photo,
            publicId: publicId,
            notify: notify
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
    /// Returns a copy with a small "Brightglow.co" mark in the bottom-right corner.
    /// This is the ONE piece of product attribution the customer can't strip in
    /// Messages (unlike a body line) — it travels with the MMS attachment itself,
    /// and points a curious business straight at the site. Applied only to the
    /// outgoing copy at send time, never to the on-screen preview, so the user
    /// reviews their own unaltered photo.
    func brightglowWatermarked() -> UIImage {
        let text = "Brightglow.co"
        // Scale the mark to the image so it reads the same on a tiny thumbnail or
        // a full-res shot; clamp so it never disappears on small images.
        let fontSize = max(size.width * 0.032, 15)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pad = fontSize * 0.7

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            draw(in: CGRect(origin: .zero, size: size))
            // A soft dark shadow keeps white legible over light subjects (tile,
            // porcelain, a white vanity) without a visible plate.
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1),
                                    blur: fontSize * 0.5,
                                    color: UIColor.black.withAlphaComponent(0.55).cgColor)
            let origin = CGPoint(x: size.width - textSize.width - pad,
                                 y: size.height - textSize.height - pad)
            (text as NSString).draw(at: origin, withAttributes: attrs)
        }
    }
}
