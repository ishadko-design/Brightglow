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
    /// The vision model's concise read of the photo ("Blue Chevrolet Volt with
    /// large dents on the front door"). Arrives asynchronously — classification
    /// finishes a beat after the canvas opens. It's a BINDING (not a plain value)
    /// on purpose: a plain value read inside a `.fullScreenCover`'s content isn't
    /// re-evaluated when the source changes later, so the description never
    /// appeared until an unrelated redraw forced a re-render (reported 2026-08-08).
    /// A binding propagates into the presented cover the same way `paths` does.
    @Binding var autoDescription: String
    /// Increments whenever a re-classification COMPLETES (see CameraViewModel).
    /// Drives the "reading that area" feedback and lets a circled read replace the
    /// field even when its text matches the previous guess. Defaults to a constant
    /// binding for callers with no live classifier (e.g. the quote-request editor).
    var classifyGeneration: Binding<Int> = .constant(0)
    /// The user circled a region — its bounding box in this view's space, plus the
    /// view size. Wired to re-classify that crop so the description disambiguates
    /// to what was circled. No-op by default (e.g. the quote-request editor).
    var onRegionDrawn: (CGRect, CGSize) -> Void = { _, _ in }
    @Binding var paths: [DrawnPath]

    @State private var description: String = ""
    /// Set once the user types their own text or taps clear — from then on the
    /// model's guess never overwrites what they chose to leave in the field.
    @State private var suppressAutofill = false
    /// The exact text we last auto-filled. Lets a fresh guess (e.g. after the user
    /// circles a region) replace an earlier guess still sitting untouched in the
    /// field, while never overwriting text the user actually typed.
    @State private var lastAutofill = ""
    /// True from the moment the user finishes a stroke until the resulting
    /// re-classification lands — drives the inline "reading that area…" spinner so
    /// a circle gives immediate feedback instead of looking like nothing happened.
    @State private var reclassifying = false
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
                // interpreting what was circled happens on the backend. Circling
                // also re-classifies that region to disambiguate the description
                // (see onRegionDrawn).
                DrawingCanvas(paths: $paths, onSelection: { box in
                    // The user already typed their own request — their intention is
                    // set, and the region read would be discarded anyway (we never
                    // overwrite typed text). So don't re-classify or show the spinner;
                    // the stroke is just an annotation baked into the photo.
                    let current = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !current.isEmpty && description != lastAutofill { return }
                    // Otherwise a finished stroke — even an open loop — is an explicit
                    // "read THIS" signal: re-fire immediately and show feedback. The
                    // region result adopts on the next classifyGeneration bump (below),
                    // filling an empty field or replacing a stale machine guess.
                    withAnimation(.easeInOut(duration: 0.15)) { reclassifying = true }
                    onRegionDrawn(box, geo.size)
                })
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
                        // Immediate feedback that a circled area is being re-read.
                        if reclassifying {
                            ThinkingOrb(size: 22, color: .white)
                                .padding(.leading, 8)
                                .transition(.opacity)
                        }
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

                        // Clear — wipes the field (mainly the auto-filled guess
                        // when it's off) and stops it from re-populating. Shown
                        // only when there's text to clear.
                        // Reserved slot (always 32pt) so the field width never
                        // jumps when the clear button appears/disappears; only its
                        // opacity animates, never the container geometry.
                        Button {
                            suppressAutofill = true
                            description = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 32, height: 32)
                        }
                        .opacity(description.isEmpty ? 0 : 1)
                        .allowsHitTesting(!description.isEmpty)
                        .animation(.easeInOut(duration: 0.15), value: description.isEmpty)
                        .accessibilityLabel("Clear text")

                        // CTA — right-pointing white arrow on blue background.
                        // Hidden until the user has given something: typed text
                        // or a drawn mark.
                        // Reserved slot (always 44pt) — fades/scales in place so the
                        // input never resizes when it becomes sendable.
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
                        .opacity(canSend ? 1 : 0)
                        .scaleEffect(canSend ? 1 : 0.8)
                        .allowsHitTesting(canSend)
                        .animation(.easeInOut(duration: 0.15), value: canSend)
                    }
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
            if description.isEmpty {
                // The user's own prior text wins and blocks the model's guess from
                // ever overwriting it.
                let prior = initialDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prior.isEmpty { description = initialDescription; suppressAutofill = true }
            }
            // Text carried over from before the photo means the user already started —
            // don't float the "draw" hint over their input.
            if !description.isEmpty { showDrawHint = false }
            applyAutofillIfPossible()   // classification may already be in
        }
        // Keep the draw hint up on a fresh photo until the user actually acts —
        // starts typing (focuses the field) or draws their first stroke — rather than
        // a blind 3s timeout that vanished before they'd read it.
        .onChange(of: inputFocused) {
            if inputFocused { withAnimation(.easeInOut(duration: 0.4)) { showDrawHint = false } }
        }
        .onChange(of: paths.isEmpty) {
            if !paths.isEmpty { withAnimation(.easeInOut(duration: 0.4)) { showDrawHint = false } }
        }
        // Classification usually returns a beat after the canvas opens — fill then.
        // Re-fires too when circling a region swaps in a new region-based guess.
        .onChange(of: autoDescription) { applyAutofillIfPossible() }
        // A re-classification COMPLETED. When triggered by a draw, adopt the region
        // read INTO an empty field or over an earlier auto-guess the user hasn't
        // touched — but NEVER over text the user typed themselves. Circling is meant
        // to disambiguate a machine guess, not to overwrite the user's own words
        // (reported 2026-09-01). Fires on the generation bump, not the text, so an
        // identical re-read still clears the spinner and counts.
        .onChange(of: classifyGeneration.wrappedValue) {
            guard reclassifying else { return }
            withAnimation(.easeInOut(duration: 0.15)) { reclassifying = false }
            let guess = autoDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !guess.isEmpty else { return }   // read failed → keep what's there
            // The field holds the user's own text when it's non-empty and isn't the
            // phrase we last auto-filled — leave it alone.
            let current = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let userTyped = !current.isEmpty && description != lastAutofill
            guard !userTyped else { return }
            suppressAutofill = false
            lastAutofill = autoDescription
            // No animation on the text write itself — animating a TextField's bound
            // string snapshots the field (material background and all) and crossfades
            // it, which read as a duplicate "background behind the input".
            description = autoDescription
        }
        // Any change we didn't make ourselves is the user typing — from then on
        // their text is theirs, and no guess (initial or region) overwrites it.
        .onChange(of: description) {
            if description != lastAutofill { suppressAutofill = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
            guard let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardHeight = frame.height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    /// True when there's something to send — typed or auto-filled text, or a drawn
    /// stroke. The model's inferred phrase now lands in the field as real,
    /// editable text the user can see (and clear), so it counts as sendable.
    private var canSend: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !paths.isEmpty
    }

    /// Write the model's inferred phrase into the input. Fills when the field is
    /// empty, or still holds an earlier auto-guess the user hasn't touched (so a
    /// region re-classification can replace it). Never overwrites text the user
    /// typed, or a field they cleared. Called on appear and whenever the model's
    /// guess changes.
    private func applyAutofillIfPossible() {
        guard !suppressAutofill,
              !autoDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              autoDescription != description
        else { return }
        let current = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || description == lastAutofill else { return }
        lastAutofill = autoDescription
        description = autoDescription
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
