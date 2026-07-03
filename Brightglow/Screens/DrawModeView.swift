import SwiftUI
import PhotosUI
import Supabase

private var safeTop: CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 54
}

private var safeBottom: CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
}

struct DrawModeView: View {
    let image: UIImage
    let onBack: () -> Void
    /// Called when the CTA (or keyboard send) is tapped. Passes the typed word
    /// and the photo with any drawn strokes baked in (unchanged if none were drawn).
    var onSubmit: (String, UIImage) -> Void = { _, _ in }
    /// What the model understood from the photo — pre-fills the input so the
    /// user sees (and can edit) the detected term before sending.
    var prefill: String = ""
    /// Whatever the user had already typed before taking the photo — carried
    /// over so switching to the camera doesn't lose it.
    var initialDescription: String = ""
    /// Category names offered in the quick-pick carousel — home trades by default,
    /// or the Auto & moto services when the photo was recognised as a vehicle.
    var categorySuggestions: [String] = Category.allCases.map(\.rawValue)
    /// Multiple detected objects — shown as tappable tags for disambiguation.
    var objects: [DetectedObject] = []
    @Binding var paths: [DrawnPath]

    @EnvironmentObject private var auth: AuthService

    @State private var description: String = ""
    /// Tags chosen from the photo — by drawing around objects or tapping the
    /// detected-object tags. Each shows as a removable chip inside the input, so
    /// the user can point at several things at once and drop any that are wrong.
    @State private var selectedTags: [String] = []
    /// Guesses from photos added mid-flow (via +) — lead the carousel so they're
    /// one tap away, but are never auto-selected unless the model was certain.
    @State private var leadSuggestions: [String] = []
    /// Once the user adds/removes a tag themselves, stop auto-applying the
    /// default pre-selection so we don't fight their choice.
    @State private var userTouched = false
    @FocusState private var inputFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    @State private var classifying = false
    @State private var classifyError: String? = nil
    @State private var showDrawHint = true
    @State private var pickedItems: [PhotosPickerItem] = []

    // ── Test-only: send the drawn photo through LeadBridge to a hardcoded
    // test address, so the relay pipeline can be exercised from the app
    // without a real contractor email source (business_enrichment isn't
    // built yet). EMAIL_OVERRIDE_TO on the backend redirects delivery
    // regardless of what's sent here.
    @State private var sendingTestLead = false
    @State private var testLeadResult: TestLeadResult? = nil
    private enum TestLeadResult: Identifiable {
        case success(publicId: String)
        case failure(String)
        var id: String {
            switch self {
            case .success(let id): return "success-\(id)"
            case .failure(let msg): return "failure-\(msg)"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Full-screen photo
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // ── Drawing canvas — circling an object re-classifies that region
                DrawingCanvas(paths: $paths) { box in
                    let viewSize = geo.size
                    classifying = true
                    classifyError = nil
                    Task {
                        do {
                            let match = try await ImageClassifier.classify(image, regionInView: box, viewSize: viewSize)
                            await MainActor.run {
                                classifying = false
                                addTag(match.label)
                            }
                        } catch {
                            await MainActor.run {
                                classifying = false
                                classifyError = "Couldn't recognize that — try again."
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(!inputFocused)

                // ── Chrome
                VStack(spacing: 0) {
                    // Back + Profile — explicitly below the status bar
                    HStack {
                        Button(action: onBack) {
                            // Match the gallery header's back control: arrow.left, 18pt semibold.
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("Back")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                        }

                        Spacer()

                        if !paths.isEmpty {
                            Button {
                                _ = withAnimation(.easeInOut(duration: 0.2)) {
                                    paths.removeLast()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Undo")
                                        .font(.bodySmall)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background {
                                    ZStack {
                                        Color.clear.background(.ultraThinMaterial)
                                        Color(red: 0x13/255, green: 0x13/255, blue: 0x15/255).opacity(0.5)
                                    }
                                }
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))

                            // TEST ONLY — sends the flattened photo (outline baked in)
                            // through LeadBridge to a hardcoded test address.
                            Button {
                                sendTestLead(viewSize: geo.size)
                            } label: {
                                if sendingTestLead {
                                    ProgressView().tint(.white)
                                        .frame(width: 16, height: 16)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                } else {
                                    Text("Send test lead")
                                        .font(.bodySmall)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                }
                            }
                            .disabled(sendingTestLead)
                            .background(AppColors.accentGradient)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: paths.isEmpty)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .padding(.top, safeTop)
                    .background(alignment: .top) { BlurredHeaderBackground() }

                    Spacer()

                    // Draw hint — shown on appear, crossfades out after 3s
                    HintPill(text: "Draw with your finger to point the issue")
                        .padding(.bottom, 16)
                        .opacity(showDrawHint ? 1 : 0)
                        .animation(.easeInOut(duration: 0.4), value: showDrawHint)

                    // Recognition error
                    if let classifyError {
                        Text(classifyError)
                            .font(.bodySmall)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    }

                    // ── Category carousel — 12pt above input bar (unselected only)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(displayedSuggestions.filter { !selectedTags.contains($0) }, id: \.self) { name in
                                categoryTag(name)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 12)
                    .allowsHitTesting(!inputFocused)

                    // Input bar — chip(s) on their own row, left-aligned above the +
                    // button; controls row (+, text field, mic, send) below.
                    VStack(alignment: .leading, spacing: 8) {
                        if !selectedTags.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(selectedTags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text(tag)
                                            .font(.bodySmall)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.15)) { removeTag(tag) }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                                .frame(width: 16, height: 16)
                                                .background(Circle().fill(.white.opacity(0.25)))
                                        }
                                    }
                                    .padding(.leading, 12)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(AppColors.accentGradient))
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            // + always on the left — add another photo mid-flow.
                            PhotosPicker(selection: $pickedItems, maxSelectionCount: 1,
                                         matching: .images, photoLibrary: .shared()) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .iconTapTarget()
                            }

                            TextField(selectedTags.isEmpty ? "Describe what you need…" : "Add details…", text: $description, axis: .vertical)
                                .font(.bodyLight)
                                .foregroundStyle(.white)
                                .tint(AppColors.accentStart)
                                .focused($inputFocused)
                                .lineLimit(1...5)
                                .submitLabel(.send)
                                .onSubmit { submit(viewSize: geo.size) }
                                .frame(minHeight: 32, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if classifying {
                                ProgressView()
                                    .tint(AppColors.accentStart)
                                    .iconTapTarget()
                            } else {
                                Image(systemName: "mic")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .iconTapTarget()
                            }

                            // CTA — right-pointing white arrow on blue background.
                            // Hidden until there's something to send (a tag or text).
                            if canSend {
                                Button(action: { submit(viewSize: geo.size) }) {
                                    ZStack {
                                        Circle().fill(AppColors.accentGradient)
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 36, height: 36)
                                }
                                .frame(width: 44, height: 44)
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: selectedTags)
                    .animation(.easeInOut(duration: 0.15), value: canSend)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(minHeight: 60)
                    .background {
                        ZStack {
                            Color.clear.background(.ultraThinMaterial)
                            AppColors.searchBg
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 32))
                    .overlay(RoundedRectangle(cornerRadius: 32).stroke(AppColors.searchBorder, lineWidth: 1.5))
                    .padding(.horizontal, 16)
                    .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 16 : safeBottom + 16)
                    .animation(.easeOut(duration: 0.25), value: keyboardHeight)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        // Modal (full-screen cover) → no system pop gesture; left-edge swipe = back.
        .edgeSwipeBack(perform: onBack)
        .onAppear {
            if description.isEmpty { description = initialDescription }
            applyDefaultSelection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showDrawHint = false }
            }
        }
        // Classification / object detection can finish just after the view
        // appears — (re)apply the single default pre-selection then.
        .onChange(of: prefill) { _, _ in applyDefaultSelection() }
        .onChange(of: objects.count as Int) { _, _ in applyDefaultSelection() }
        // Typing a recognized term ("roofing", "electrical", …) auto-adds it as a tag.
        .onChange(of: description) { _, text in
            guard let cat = Category.exactTerm(text) else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                addTag(cat.rawValue)
                description = ""
            }
        }
        .onChange(of: pickedItems) { _, items in addPickedPhoto(items) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
            guard let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardHeight = frame.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .alert(item: $testLeadResult) { result in
            switch result {
            case .success(let publicId):
                return Alert(title: Text("Sent"), message: Text("Lead \(publicId) sent — check the test inbox."), dismissButton: .default(Text("OK")))
            case .failure(let message):
                return Alert(title: Text("Failed to send"), message: Text(message), dismissButton: .default(Text("OK")))
            }
        }
    }

    /// TEST ONLY — flattens the drawn outline onto the photo and posts it to
    /// LeadBridge. Real contractor-email sourcing (business_enrichment)
    /// isn't built yet, so contractorEmail is hardcoded to the Brightglow
    /// test inbox — but userEmail is the real signed-in user, not a
    /// placeholder, so this exercises the real two-party relay: the actual
    /// registered user on one side, the test inbox standing in for the
    /// contractor on the other.
    ///
    /// Both addresses must be real (not fake placeholders) because
    /// LeadBridge's reply-relay only accepts replies from a lead's actual
    /// stored contractor_email/user_email — that's what stops strangers
    /// hijacking a thread. EMAIL_OVERRIDE_TO only redirects where
    /// notification mail is *delivered*, it doesn't relax that check.
    private func sendTestLead(viewSize: CGSize) {
        guard !sendingTestLead else { return }
        guard let userEmail = auth.user?.email, !userEmail.isEmpty else {
            testLeadResult = .failure("No signed-in email found — sign in again and retry.")
            return
        }
        sendingTestLead = true
        let flattened = image.flattened(withStrokes: paths, viewSize: viewSize)
        let desc = ([description.trimmingCharacters(in: .whitespacesAndNewlines)] + selectedTags)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let finalDescription = desc.isEmpty ? "Test request from Brightglow draw mode" : desc

        Task {
            do {
                let publicId = try await LeadBridgeService.submitLead(
                    userEmail: userEmail,
                    contractorEmail: "hello@brightglow.co",
                    description: finalDescription,
                    city: "Test City",
                    photo: flattened
                )
                await MainActor.run {
                    sendingTestLead = false
                    testLeadResult = .success(publicId: publicId)
                }
            } catch {
                await MainActor.run {
                    sendingTestLead = false
                    testLeadResult = .failure("\(error)")
                }
            }
        }
    }

    /// Carousel order: guesses from photos added mid-flow lead, then the
    /// suggestions computed for the captured photo.
    private var displayedSuggestions: [String] {
        leadSuggestions + categorySuggestions.filter { !leadSuggestions.contains($0) }
    }

    /// Classify a photo added via the + — same confidence gating as the capture:
    /// a certain verdict becomes a tag; weak guesses only lead the carousel.
    private func addPickedPhoto(_ items: [PhotosPickerItem]) {
        guard let item = items.last else { return }
        classifying = true
        Task {
            var suggestions: ImageClassifier.Suggestions? = nil
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                suggestions = await ImageClassifier.suggestTrades(img)
            }
            await MainActor.run {
                classifying = false
                pickedItems = []
                guard let suggestions else { return }
                if let confident = suggestions.confident { addTag(confident.label) }
                let labels = suggestions.matches.map(\.label).filter { !selectedTags.contains($0) }
                leadSuggestions = labels + leadSuggestions.filter { !labels.contains($0) }
            }
        }
    }

    /// True when there's something to send — a selected tag or typed text. Gates
    /// the CTA's visibility and the keyboard send.
    private var canSend: Bool {
        !selectedTags.isEmpty
            || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send the query: combine typed details with all selected tags, and bake
    /// any drawn strokes into the photo so what gets carried forward matches
    /// what the user saw on screen.
    private func submit(viewSize: CGSize) {
        inputFocused = false
        guard canSend else { return }
        let typed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ([typed] + selectedTags).filter { !$0.isEmpty }
        let flattened = image.flattened(withStrokes: paths, viewSize: viewSize)
        onSubmit(parts.joined(separator: ", "), flattened)
    }

    /// Pre-select a tag only when the classifier was confident about a single
    /// clear subject (`prefill` is empty otherwise). If the photo's subjects span
    /// both verticals (e.g. a car AND a house), it's ambiguous — preselect nothing
    /// and let the user pick from the carousel, which is ordered so the dominant
    /// subject's tags come first. Stops once the user has made their own choice.
    private func applyDefaultSelection() {
        guard !userTouched else { return }
        if Set(objects.map(\.match.isAuto)).count > 1 { selectedTags = []; return }
        selectedTags = prefill.isEmpty ? [] : [prefill]
    }

    /// Add a tag (deduped, order preserved). User-initiated.
    private func addTag(_ raw: String) {
        userTouched = true
        guard !selectedTags.contains(raw) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { selectedTags.append(raw) }
    }

    private func removeTag(_ raw: String) {
        userTouched = true
        selectedTags.removeAll { $0 == raw }
    }

    /// Tapping a detected-object tag toggles it in/out of the selection.
    private func toggleTag(_ raw: String) {
        if selectedTags.contains(raw) { removeTag(raw) } else { addTag(raw) }
    }

    @ViewBuilder
    private func categoryTag(_ raw: String) -> some View {
        let isSelected = selectedTags.contains(raw)
        Button {
            toggleTag(raw)
            classifyError = nil
        } label: {
            Text(raw)
                .font(.bodySmall)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        AppColors.accentGradient
                    } else {
                        ZStack {
                            Color.clear.background(.ultraThinMaterial)
                            Color(red: 0x13/255, green: 0x13/255, blue: 0x15/255).opacity(0.6)
                        }
                    }
                }
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
    }


    /// Map a normalized Vision rect (origin bottom-left) to a point in the
    /// scaledToFill photo's view coordinates, clamped on-screen.
    private func tagPoint(_ box: CGRect, in viewSize: CGSize) -> CGPoint {
        let isz = image.size
        let scale = max(viewSize.width / isz.width, viewSize.height / isz.height)
        let dispW = isz.width * scale, dispH = isz.height * scale
        let offsetX = (dispW - viewSize.width) / 2
        let offsetY = (dispH - viewSize.height) / 2
        let x = box.midX * dispW - offsetX
        let y = (1 - box.midY) * dispH - offsetY
        return CGPoint(x: min(max(x, 56), viewSize.width - 56),
                       y: min(max(y, 120), viewSize.height - 160))
    }
}
