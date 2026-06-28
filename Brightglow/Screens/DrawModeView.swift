import SwiftUI

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
    /// Called when the CTA (or keyboard send) is tapped. Passes the typed word.
    var onSubmit: (String) -> Void = { _ in }
    /// What the model understood from the photo — pre-fills the input so the
    /// user sees (and can edit) the detected term before sending.
    var prefill: String = ""
    /// Multiple detected objects — shown as tappable tags for disambiguation.
    var objects: [DetectedObject] = []
    @Binding var paths: [DrawnPath]

    @State private var description: String = ""
    /// Tags chosen from the photo — by drawing around objects or tapping the
    /// detected-object tags. Each shows as a removable chip inside the input, so
    /// the user can point at several things at once and drop any that are wrong.
    @State private var selectedTags: [String] = []
    /// Once the user adds/removes a tag themselves, stop auto-applying the
    /// default pre-selection so we don't fight their choice.
    @State private var userTouched = false
    @FocusState private var inputFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    @State private var classifying = false
    @State private var classifyError: String? = nil
    @State private var showDrawHint = true

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
                            let cat = try await ImageClassifier.classify(image, regionInView: box, viewSize: viewSize)
                            await MainActor.run {
                                classifying = false
                                addTag(cat.rawValue)
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
                            ForEach(Category.allCases.filter { !selectedTags.contains($0.rawValue) }, id: \.self) { cat in
                                categoryTag(cat.rawValue)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 12)
                    .allowsHitTesting(!inputFocused)

                    // Input bar — chip(s) pinned top-left, text field below, buttons right.
                    HStack(alignment: selectedTags.isEmpty ? .center : .bottom, spacing: 8) {
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

                            TextField(selectedTags.isEmpty ? "Describe what you need…" : "Add details…", text: $description, axis: .vertical)
                                .font(.bodyLight)
                                .foregroundStyle(.white)
                                .tint(AppColors.accentStart)
                                .focused($inputFocused)
                                .lineLimit(1...5)
                                .submitLabel(.send)
                                .onSubmit(submit)
                                .frame(minHeight: 32, alignment: .leading)
                        }
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

                        // CTA — right-pointing white arrow on blue background
                        Button(action: submit) {
                            ZStack {
                                Circle().fill(AppColors.accentGradient)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 36, height: 36)
                        }
                        .frame(width: 44, height: 44)
                    }
                    .animation(.easeInOut(duration: 0.15), value: selectedTags)
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
        .onAppear {
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
            guard let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardHeight = frame.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    /// Send the query: combine typed details with all selected tags.
    private func submit() {
        inputFocused = false
        let typed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ([typed] + selectedTags).filter { !$0.isEmpty }
        onSubmit(parts.joined(separator: ", "))
    }

    /// By default pre-select exactly ONE token: the highest-confidence object by
    /// area when objects were detected, else the whole-image classification.
    /// Other possibilities stay as selectable tags on the image, not in the input.
    /// Stops once the user has made their own selection.
    private func applyDefaultSelection() {
        guard !userTouched else { return }
        if let best = objects.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            selectedTags = [best.category.rawValue]
        } else if !prefill.isEmpty {
            selectedTags = [prefill]
        }
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
