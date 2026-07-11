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

/// Full-screen photo + finger-drawing overlay shown right after a capture (and
/// as the annotation editor from the quote-request screen). The user circles
/// the problem and/or types a description; nothing is classified or tokenized
/// on-device here — the drawn photo is carried forward as-is and interpreted
/// by the backend.
struct DrawModeView: View {
    let image: UIImage
    let onBack: () -> Void
    /// Called when the CTA (or keyboard send) is tapped. Passes the typed text
    /// (may be empty when the user only drew) and the photo with any drawn
    /// strokes baked in (unchanged if none were drawn).
    var onSubmit: (String, UIImage) -> Void = { _, _ in }
    /// Whatever the user had already typed before taking the photo — carried
    /// over so switching to the camera doesn't lose it.
    var initialDescription: String = ""
    @Binding var paths: [DrawnPath]

    @State private var description: String = ""
    @FocusState private var inputFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
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

                // ── Drawing canvas — strokes are baked into the photo at submit;
                // interpreting what was circled happens on the backend.
                DrawingCanvas(paths: $paths)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(!inputFocused)

                // ── Chrome
                VStack(spacing: 0) {
                    // Back + Undo — explicitly below the status bar
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

                    // Input bar — text field + send.
                    HStack(spacing: 8) {
                        TextField("Describe what you need…", text: $description, axis: .vertical)
                            .font(.bodyLight)
                            .foregroundStyle(.white)
                            .tint(AppColors.accentStart)
                            .focused($inputFocused)
                            .lineLimit(1...5)
                            .submitLabel(.go)
                            .onSubmit { submit(viewSize: geo.size) }
                            .frame(minHeight: 32, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)

                        // CTA — right-pointing white arrow on blue background.
                        // Hidden until the user has given something: typed text
                        // or a drawn mark.
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
        // Swipe down anywhere to dismiss the keyboard. Without this the field can
        // trap the user: while it's focused the drawing canvas is disabled, so the
        // screen looks frozen with no way back to drawing. Gated to only fire while
        // the keyboard is up, so it never steals a downward drawing stroke.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    if value.translation.height > 20 { inputFocused = false }
                },
            including: inputFocused ? .all : .none
        )
        // Modal (full-screen cover) → no system pop gesture; left-edge swipe = back.
        .edgeSwipeBack(perform: onBack)
        .onAppear {
            if description.isEmpty { description = initialDescription }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showDrawHint = false }
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

    /// True when the user has actually given input — typed text or a drawn
    /// stroke. An untouched screen shows no CTA (the model's own guess about
    /// the photo never counts as user input).
    private var canSend: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !paths.isEmpty
    }

    /// Send the typed text (possibly empty when the user only drew) and bake any
    /// drawn strokes into the photo, so what gets carried forward matches what
    /// the user saw on screen.
    private func submit(viewSize: CGSize) {
        inputFocused = false
        guard canSend else { return }
        let flattened = image.flattened(withStrokes: paths, viewSize: viewSize)
        onSubmit(description.trimmingCharacters(in: .whitespacesAndNewlines), flattened)
    }
}
