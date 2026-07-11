import SwiftUI
import CoreLocation
import PhotosUI

/// A contractor destination awaiting a resolved location before it can open.
private enum PendingDestination {
    case home(Category)
    case auto(AutoCategory)
}

/// One bubble of the clarifying chat the input pill transforms into.
private struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String   // "user" | "assistant"
    let content: String
}

struct MainScreen: View {
    @StateObject private var camera = CameraViewModel()
    @StateObject private var locationStore = LocationStore()
    @EnvironmentObject private var chatRouter: ChatRouter
    /// Landing opens compact (just the two vertical tiles); expands to .full when
    /// a vertical is opened so its category grid can scroll.
    @State private var sheetDetent: SheetDetent = .mid
    @State private var sheetScrolledToTop = true
    @State private var goSwipe: Category? = nil
    @State private var goSearch = false
    /// Landing sheet drill-down: nil = vertical chooser, else that vertical's grid.
    @State private var selectedVertical: Vertical? = nil
    /// Auto & moto category the user tapped; drives the contractor list.
    @State private var goAuto: AutoCategory? = nil
    @State private var submittedQuery = ""
    /// Photo-derived cost-relevant attributes (size, capacity, material) from
    /// the most recent capture, carried to the contractor list to narrow the
    /// price estimate only — never used for the business search itself.
    @State private var photoDetails: String? = nil
    /// What the last captured photo *shows* — detected vehicle type + trade +
    /// visible attributes — sent to the clarify chat so it doesn't re-ask what
    /// the image already answers (e.g. "car or motorcycle?" for a plain car
    /// photo). Distinct from `photoDetails`, which is cost-only and feeds pricing.
    @State private var photoContext: String? = nil
    @State private var searchText = ""
    // ── Clarifying chat — after a typed request, the input pill grows into a
    // small chat card where the AI asks a scalable number of questions (1 for a
    // clear job, up to ~7 for an ambiguous one) to disambiguate toward the right
    // business, then opens results. Any service failure skips straight to
    // results, so the flow never blocks on the chat.
    @State private var chatMessages: [ChatMessage] = []
    @State private var chatQuickReplies: [String] = []
    @State private var chatActive = false
    @State private var chatLoading = false
    /// Chat outcome. `chatSearchTerms` refines the business search and
    /// `chatPhotoTerms` ranks each business's photos ("did a similar job");
    /// `chatDetails`/`chatPriceable` are the secondary pricing layer.
    @State private var chatDetails: String? = nil
    @State private var chatCategory = ""
    @State private var chatSearchTerms = ""
    @State private var chatPhotoTerms = ""
    /// Whether a real price is expected (covered home trade). Auto/moto and
    /// uncovered categories are match-only, so the list shows no number.
    @State private var chatPriceable = true
    /// The snapped photo (strokes baked in) shown behind the clarifying chat when
    /// the chat was started from a capture — so the user keeps seeing what they
    /// photographed while answering. Nil for a plain typed search (live camera
    /// stays as the backdrop).
    @State private var clarifyBackdrop: UIImage? = nil
    @State private var locationQuery = ""
    /// True while the user is editing the location (typing a ZIP) — kept separate
    /// from @FocusState so the "Current location" CTA shows reliably on tap.
    @State private var editingLocation = false
    /// Destination the user tapped before a location was available; navigates once
    /// a location resolves. Contractors are never shown without a location.
    @State private var pendingDestination: PendingDestination? = nil
    @State private var drawnPaths: [DrawnPath] = []
    /// The captured photo (with any drawn strokes baked in) carried forward to
    /// the quote-request screen once the user reaches a contractor.
    @State private var attachedImages: [UIImage] = []
    @State private var showProfile = false
    /// Pushes the conversations inbox from the header chat icon.
    @State private var showChat = false
    /// Lights the orange dot on the chat icon when a counterparty has sent a
    /// message since the inbox was last opened.
    @State private var hasUnreadChat = false
    /// Coaching hint above the shutter — appears when the sheet is pulled down to
    /// expose the full camera, then auto-dismisses after a few seconds.
    @State private var showCameraHint = false
    /// Native photo-picker selection (raw items) and the decoded images shown
    /// as thumbnails above the input bar.
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pickedImages: [UIImage] = []
    /// Live keyboard height — drives the dark fill behind the keyboard so it
    /// covers exactly the keyboard (not the camera/input above it).
    @State private var keyboardHeight: CGFloat = 0
    /// Measured height of the input pill — drives the shutter's clearance so it
    /// always sits ≥16pt above the bar, even when it grows (thumbnails, multi-line).
    @State private var inputBarHeight: CGFloat = 60
    @FocusState private var searchFocused: Bool
    @FocusState private var locationFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Fixed landing height (Figma node 466:1813). The sheet's bottom ==
                // screen bottom and its content is top-anchored, so the tiles' lower
                // edge sits 126pt above the screen bottom:
                //   midHeight = 126 (tile-bottom inset) + 242 (tile height)
                //             + 12 (title→grid spacing) + 29 (h2 title line)
                //             + 4 (grid top pad) + 25 (grab handle) = 438
                // Not retractable (only two categories) — this is its only height.
                let midHeight: CGFloat = 438
                let collapsedHeight: CGFloat = 180
                let headerInset: CGFloat = 76   // 60pt header (44 + 8/8 padding) + 16pt gap to the sheet
                // True whenever a text field (search OR the location/ZIP field) has
                // raised the keyboard — both should dock the input bar to it.
                let keyboardActive = searchFocused || locationFocused
                // The landing sheet rests at midHeight but can be dragged down to
                // collapsed (full camera). The shutter tracks it: 16pt above the
                // sheet's current resting height — or, when the keyboard is up, above
                // the input bar (which sits 16pt above the keyboard) with a 24pt gap.
                let restingSheetHeight = sheetDetent == .collapsed ? collapsedHeight : midHeight
                let shutterPad: CGFloat = keyboardActive ? (inputBarHeight + 16 + 24) : (restingSheetHeight + 16)

                ZStack(alignment: .bottom) {

                    // ── Full-screen camera (live)
                    CameraScreen(camera: camera)
                        .ignoresSafeArea()

                    // ── Captured photo, held behind the clarifying chat ──────────
                    // The chat is about THIS photo, so it stays on screen (over the
                    // live preview) for the whole conversation instead of snapping
                    // back to the viewfinder.
                    if chatActive, let backdrop = clarifyBackdrop {
                        Image(uiImage: backdrop)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .ignoresSafeArea()
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }

                    // ── Dim overlay — only when collapsed (camera exposed)
                    Color.black
                        .opacity(sheetDetent == .collapsed ? 0.15 : 0)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: 0.3), value: sheetDetent)

                    // ── Header: location picker (left) + profile (right)
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            locationPicker
                            Spacer(minLength: 0)
                            // Chat + profile sit flush together on the right (Figma
                            // header: two 44pt tap targets, no gap between them).
                            HStack(spacing: 0) {
                                Button(action: { openChat() }) {
                                    // Plain glyph, no background — same flat style as
                                    // the profile icon (white, line icon). Exact Figma
                                    // chat bubble (typing dots) exported as a template
                                    // asset — no SF Symbol matches it.
                                    Image("ic_chat")
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(.white)
                                        // Unread dot (Figma): 8pt orange fill sitting on
                                        // the bubble's lower-right, ringed by a 2pt white
                                        // border so it reads against the photo behind.
                                        .overlay(alignment: .bottomTrailing) {
                                            if hasUnreadChat {
                                                ZStack {
                                                    Circle()
                                                        .fill(.white)
                                                        .frame(width: 12, height: 12)
                                                    Circle()
                                                        .fill(DesignTokens.colorOrange)
                                                        .frame(width: 8, height: 8)
                                                }
                                                .offset(x: 1, y: 1)
                                            }
                                        }
                                        .iconTapTarget()
                                }
                                Button(action: { showProfile = true }) {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 24, weight: .regular))
                                        .foregroundStyle(.white)
                                        .iconTapTarget()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(alignment: .top) { BlurredHeaderBackground() }
                        Spacer()
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(!searchFocused && !chatActive)

                    // ── Shutter button — always shown on the landing chooser (it sits
                    // 16pt above the fixed categories sheet). When the camera is
                    // authorized it's the capture button; before access is granted it
                    // becomes the dark camera-icon disc that requests permission
                    // (Figma: Main – Before permissions).
                    if selectedVertical == nil && !chatActive {
                        VStack(spacing: 0) {
                            Spacer()
                            // Coaching hint — appears when the sheet is pulled down to
                            // expose the full camera, then crossfades out after 3s
                            // (driven by showCameraHint). 16pt above the shutter.
                            if sheetDetent == .collapsed && camera.isAuthorized && !searchFocused {
                                HintPill(text: "Add a picture and explain your task to connect with businesses.")
                                    .opacity(showCameraHint ? 1 : 0)
                                    .animation(.easeInOut(duration: 0.4), value: showCameraHint)
                                    .padding(.bottom, 16)
                            }
                            Group {
                                if camera.isAuthorized {
                                    Button(action: { camera.capturePhoto() }) {
                                        ZStack {
                                            Circle()
                                                .fill(AppColors.shutterBg)
                                            Circle()
                                                .strokeBorder(AppColors.shutterBorder, lineWidth: 3)
                                            Circle()
                                                .strokeBorder(AppColors.shutterRing, lineWidth: 9)
                                                .scaleEffect(1.18)
                                        }
                                        .frame(width: 72, height: 72)
                                        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)
                                    }
                                } else {
                                    // Pre-permissions CTA: a denied user is sent to
                                    // Settings (iOS won't re-prompt); otherwise this
                                    // triggers the system camera prompt.
                                    Button(action: {
                                        if camera.permissionDenied {
                                            camera.openSettings()
                                        } else {
                                            Task { await camera.requestPermissionAndStart() }
                                        }
                                    }) {
                                        ZStack {
                                            Circle().fill(.ultraThinMaterial)
                                            Circle().fill(Color.black.opacity(0.3))
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 26))
                                                .foregroundStyle(.white)
                                        }
                                        .frame(width: 88, height: 88)
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 3))
                                        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4)
                                    }
                                }
                            }
                            .padding(.bottom, shutterPad)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: selectedVertical)
                        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: sheetDetent)
                        .animation(.easeOut(duration: 0.25), value: searchFocused)
                        .animation(.easeInOut(duration: 0.25), value: camera.isAuthorized)
                        .allowsHitTesting(!searchFocused && !chatActive)
                    }

                    // ── Categories sheet — rests at midHeight; on the landing it can
                    // be dragged down to expose the full camera, but not expanded
                    // (only two categories). Drilled-in grids are full + button-driven.
                    BottomSheet(
                        detent: $sheetDetent,
                        contentIsAtTop: sheetScrolledToTop,
                        collapsedHeight: collapsedHeight,
                        midHeight: midHeight,
                        fullTopInset: headerInset,
                        dragEnabled: true,
                        expandable: false,
                        // In a drilled-in grid (.full), a downward drag pops back to
                        // the chooser instead of collapsing to the camera.
                        onDismiss: selectedVertical == nil ? nil : {
                            withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) {
                                selectedVertical = nil
                                sheetDetent = .mid
                            }
                        }
                    ) {
                        Group {
                            switch selectedVertical {
                            case .none:
                                // Landing: top-level vertical chooser
                                GridSheet(title: "Categories",
                                          isScrolledToTop: $sheetScrolledToTop) {
                                    ForEach(Vertical.allCases) { vertical in
                                        TaskCard(title: vertical.rawValue,
                                                 assetName: vertical.assetName,
                                                 height: 242) {
                                            withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) {
                                                selectedVertical = vertical
                                                sheetDetent = .full
                                            }
                                        }
                                    }
                                }
                            case .home:
                                GridSheet(title: "Home",
                                          onBack: { withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) { selectedVertical = nil; sheetDetent = .mid } },
                                          isScrolledToTop: $sheetScrolledToTop) {
                                    ForEach(categoryItems) { item in
                                        TaskCard(title: item.category.rawValue,
                                                 assetName: item.assetName) {
                                            openIfLocated(.home(item.category))
                                        }
                                    }
                                }
                            case .auto:
                                GridSheet(title: "Auto and moto",
                                          onBack: { withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) { selectedVertical = nil; sheetDetent = .mid } },
                                          isScrolledToTop: $sheetScrolledToTop) {
                                    ForEach(autoCategoryItems) { item in
                                        TaskCard(title: item.name,
                                                 assetName: item.assetName) {
                                            openIfLocated(.auto(item))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Fully hidden while the clarifying chat is up — the category
                    // tiles otherwise peek out from behind the chat card.
                    .opacity(chatActive ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: chatActive)
                    .allowsHitTesting(!searchFocused && !chatActive)

                    // ── Solid fill behind the (translucent) keyboard ─────────────
                    // Sized to the exact keyboard height and pinned to the screen
                    // bottom, so it fills ONLY behind the keyboard — it must not reach
                    // above the input bar, or it shows as a dark block that hides the
                    // floating input's rounded corners.
                    if keyboardHeight > 0 {
                        AppColors.bg
                            .frame(height: keyboardHeight)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .ignoresSafeArea(.keyboard, edges: .bottom)
                            .ignoresSafeArea(.container, edges: .bottom)
                            .allowsHitTesting(false)
                    }

                    // ── Gradient fade into search bar — hidden when the SEARCH field
                    // is focused or the chat card is up (both expand the input area
                    // and the fade would float mid-screen)
                    if !searchFocused && !chatActive {
                        LinearGradient(
                            stops: [
                                .init(color: AppColors.bg.opacity(0), location: 0),
                                .init(color: AppColors.bg,            location: 0.55),
                                .init(color: AppColors.bg,            location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 200)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.25), value: searchFocused)
                    }

                    // ── Search / input bar (grows into the clarifying chat card)
                    VStack(spacing: 10) {
                      if chatActive {
                          chatPanel
                              .transition(.move(edge: .bottom).combined(with: .opacity))
                      }
                      // Attached-photo thumbnails — horizontal strip above the field.
                      // Both the camera capture (attachedImages) and library picks
                      // (pickedImages) show here so a snapped photo stays visible on
                      // the landing after a round trip into results and back.
                      if !attachedImages.isEmpty || !pickedImages.isEmpty {
                          ScrollView(.horizontal, showsIndicators: false) {
                              HStack(spacing: 8) {
                                  ForEach(Array(attachedImages.enumerated()), id: \.offset) { index, image in
                                      thumbnail(image) { removeAttachedImage(at: index) }
                                  }
                                  ForEach(Array(pickedImages.enumerated()), id: \.offset) { index, image in
                                      thumbnail(image) { removePickedImage(at: index) }
                                  }
                              }
                              .padding(.horizontal, 4)
                          }
                          .frame(height: 56)
                      }
                      HStack(alignment: .center, spacing: 12) {
                        // + is always on the left and stays put while typing — add
                        // a photo at any point in the search.
                        PhotosPicker(
                            selection: $pickedItems,
                            maxSelectionCount: 5,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.5))
                                .iconTapTarget()
                        }

                        TextField(chatActive ? "Your answer…" : "What do you need help with?",
                                  text: $searchText, axis: .vertical)
                            .font(.bodyLight)
                            .foregroundStyle(.white)
                            .tint(AppColors.accentStart)
                            .focused($searchFocused)
                            .lineLimit(1...5)
                            .submitLabel(.search)
                            .onSubmit {
                                if chatActive { sendChatReply(searchText) } else { startClarify() }
                            }

                        // Trailing: send arrow once there's text. (Voice/mic is
                        // hidden until the feature is enabled.)
                        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(action: {
                                if chatActive { sendChatReply(searchText) } else { startClarify() }
                            }) {
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
                      }
                      .animation(.easeInOut(duration: 0.15), value: searchText.isEmpty)
                    }
                    .onChange(of: pickedItems) { _, items in
                        loadPickedImages(items)
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputBarHeight = $0 }
                    .padding(.horizontal, 16)
                    .padding(.bottom, keyboardActive ? 16 : 34)
                    .animation(.easeOut(duration: 0.25), value: searchFocused)
                    .animation(.easeOut(duration: 0.25), value: locationFocused)
                    .animation(.easeInOut(duration: 0.25), value: chatActive)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                // Swipe down ANYWHERE on screen dismisses the keyboard —
                // simultaneous, not .gesture, so child recognizers (camera
                // preview, sheet, chat) can't swallow the drag; the mask
                // keeps it inert while no keyboard is up.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            if value.translation.height > 20 {
                                searchFocused = false
                                locationFocused = false
                            }
                        },
                    including: (searchFocused || locationFocused) ? .all : .none
                )
                .navigationBarHidden(true)
                // Camera viewfinder is always exposed above the fixed sheet, so
                // resume the session whenever the landing reappears. Also grab the
                // user's location automatically when permission is already granted.
                .onAppear {
                    camera.activateIfNeeded()
                    autoFetchLocationIfGranted()
                    consumePendingChatDeepLink()   // e.g. a business arriving right after login
                    refreshChatUnread()
                }
                // A brightglow://chat deep link that fires while the app is
                // already on the landing opens the inbox immediately.
                .onChange(of: chatRouter.openInboxRequested) { _, _ in
                    consumePendingChatDeepLink()
                }
                // Power the camera down when leaving the landing (drilling into a
                // category/gallery) so the green in-use dot disappears; onAppear
                // resumes it on return.
                .onDisappear {
                    camera.deactivate()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notif in
                    if let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                        keyboardHeight = frame.height
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    keyboardHeight = 0
                }
                .navigationDestination(isPresented: Binding(
                    get: { goSwipe != nil },
                    set: { if !$0 { goSwipe = nil } }
                )) {
                    ContractorListScreen(category: goSwipe?.rawValue ?? "",
                                         presetCoordinate: locationStore.coordinate,
                                         attachedImages: attachedImages,
                                         photoDetails: photoDetails)
                }
                .navigationDestination(isPresented: $showChat) {
                    ConversationsListScreen()
                }
                .navigationDestination(isPresented: $goSearch) {
                    // goSearch is reached either from the camera flow (attachedImages
                    // set) or the search bar's own + picker (pickedImages, up to 5).
                    // The clarifying chat's outcome drives the match: search_terms
                    // refines the business query (with a fallback to the raw text),
                    // photo_terms rank each business's photos, priceable gates price.
                    ContractorListScreen(category: chatCategory,
                                         searchQuery: submittedQuery,
                                         presetCoordinate: locationStore.coordinate,
                                         attachedImages: attachedImages.isEmpty ? pickedImages : attachedImages,
                                         photoDetails: mergedDetails,
                                         businessSearchOverride: chatSearchTerms,
                                         photoMatchTerms: chatPhotoTerms,
                                         priceable: chatPriceable)
                }
                .navigationDestination(isPresented: Binding(
                    get: { goAuto != nil },
                    set: { if !$0 { goAuto = nil } }
                )) {
                    ContractorListScreen(category: goAuto?.name ?? "",
                                         searchQuery: goAuto?.searchQuery ?? "",
                                         presetCoordinate: locationStore.coordinate,
                                         attachedImages: attachedImages)
                }
                // Returning from results: put the submitted query back in the
                // field so the user's typed input survives the round trip.
                // (Images are never cleared on submit — see startClarify —
                // so photos and picked thumbnails survive on their own.)
                .onChange(of: goSearch) { _, active in
                    if !active && !submittedQuery.isEmpty {
                        searchText = submittedQuery
                    }
                    // Release the chat backdrop on the way back — held through the
                    // push so the chat's fade-out has something to fade.
                    if !active { clarifyBackdrop = nil }
                }
                // Once a location resolves (GPS fix or manual ZIP/city), continue
                // to the destination the user tapped while it was still missing.
                .onChange(of: locationStore.coordinate?.latitude) { _, _ in
                    if locationStore.coordinate != nil, let pending = pendingDestination {
                        pendingDestination = nil
                        navigate(to: pending)
                    }
                }
                .onChange(of: locationStore.authorization) { _, status in
                    switch status {
                    case .authorizedWhenInUse, .authorizedAlways:
                        autoFetchLocationIfGranted()              // just granted → capture location
                    case .denied, .restricted:
                        if pendingDestination != nil { locationFocused = true }   // can't use GPS → type a ZIP
                    default:
                        break
                    }
                }
                .onChange(of: locationStore.label) { _, newLabel in
                    if let newLabel { locationQuery = newLabel }
                }
                // Show the coaching hint each time the camera is fully exposed,
                // then fade it out after 3s.
                .onChange(of: sheetDetent) { _, newDetent in
                    if newDetent == .collapsed {
                        showCameraHint = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { showCameraHint = false }
                        }
                    } else {
                        showCameraHint = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showProfile) {
            ProfileScreen()
        }
        // ── Draw mode — proper full-screen cover with its own layout + keyboard handling
        .fullScreenCover(isPresented: $camera.showDrawingCanvas) {
            if let img = camera.capturedImage {
                DrawModeView(
                    image: img,
                    onBack: {
                        camera.retake()
                        drawnPaths = []
                        attachedImages = []
                    },
                    onSubmit: { word, resultImage in
                        // Dismiss the capture cover, then open the matching results:
                        // typed word wins (free-text search); else route by the
                        // photo's detected trade — auto → auto providers, home →
                        // the home category deck; else a mixed search.
                        let q = word.trimmingCharacters(in: .whitespacesAndNewlines)
                        let detected = camera.detectedMatch
                        let details = camera.detectedDetails
                        // Capture the vehicle guess before `retake()` clears it, so
                        // the clarify chat knows this is a car/moto and won't ask.
                        let context = Self.clarifyPhotoContext(
                            match: detected ?? camera.suggestedMatches.first,
                            vehicle: camera.detectedVehicle, details: details)
                        attachedImages = [resultImage]
                        camera.retake()
                        drawnPaths = []
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            photoDetails = details
                            photoContext = context
                            if !q.isEmpty {
                                // Through the clarify chat, same as a typed
                                // search — the photo's extracted details ride
                                // along as chat context (see advanceChat), and
                                // the photo itself stays on screen behind it.
                                startClarify(query: q, backdrop: resultImage)
                            } else {
                                switch detected {
                                case .home(let cat): goSwipe = cat
                                case .auto(let auto): goAuto = auto
                                case nil:
                                    submittedQuery = ""
                                    goSearch = true
                                }
                            }
                        }
                    },
                    initialDescription: searchText,
                    paths: $drawnPaths
                )
            }
        }
    }

    // ── Header location picker (Figma 357-862 / 1-1080) ───────────────────────
    // Pin icon + city / ZIP field. The "Current location" CTA shows when there is
    // no location yet, or while editing (to re-fetch). Once a location is fetched,
    // the CTA hides and the city is tappable to type a ZIP.
    // CTA shows when there's no location yet, while editing, or during a fetch —
    // so tapping the city always surfaces a way to re-fetch.
    private var showLocationCTA: Bool {
        !locationStore.hasLocation || editingLocation || locationStore.isResolving
    }

    private var locationPicker: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image("ic_location")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.white)

                if locationStore.hasLocation && !editingLocation {
                    // Fetched + idle: tap the city (≥44pt target) to type a ZIP.
                    Button(action: beginEditingLocation) {
                        Text(locationStore.label ?? "")
                            .font(.h4)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    TextField("Enter zip code", text: $locationQuery)
                        .font(.h4)
                        .foregroundStyle(.white)
                        .tint(AppColors.accentStart)
                        .focused($locationFocused)
                        .submitLabel(.go)
                        .fixedSize(horizontal: true, vertical: false)  // width = entered text
                        .frame(minWidth: 92, minHeight: 44)
                        .onSubmit {
                            locationStore.setManualLocation(locationQuery)
                            editingLocation = false
                            locationFocused = false
                        }
                }
            }

            if showLocationCTA {
                Button(action: fetchCurrentLocation) {
                    Group {
                        if locationStore.isResolving {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Text("Current location")
                                .font(.h4)
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 29)
                    .secondaryButtonBackground()
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ── Clarifying chat ────────────────────────────────────────────────────────

    /// Photo-derived attributes plus what the chat pinned down — the pricing
    /// request's detail text. Nil when neither exists.
    private var mergedDetails: String? {
        let parts = [photoDetails, chatDetails]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Start the clarifying chat instead of navigating straight to results.
    /// Falls through to direct navigation when the service isn't configured.
    /// `query` defaults to the search field text (the plain typed path);
    /// the camera/photo flow passes its typed word, so a photo submit gets
    /// the same price-relevant questions — with the photo's extracted
    /// attributes as chat context — instead of skipping straight to an
    /// unclarified estimate.
    ///
    /// Attached images are never cleared here: the user's photo must survive
    /// the round trip into results and back (the draw canvas's own back
    /// button is the only place a photo is discarded, explicitly).
    /// `backdrop` is the capture the chat is about, shown behind it. Always
    /// assigned (nil for a typed search), so a photo from an earlier capture can
    /// never linger behind an unrelated conversation.
    private func startClarify(query: String? = nil, backdrop: UIImage? = nil) {
        let q = (query ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        submittedQuery = q
        chatDetails = nil
        chatCategory = ""
        chatSearchTerms = ""
        chatPhotoTerms = ""
        chatPriceable = true
        clarifyBackdrop = backdrop
        guard ClarifyService.isConfigured else {
            searchFocused = false
            goSearch = true
            return
        }
        chatMessages = [ChatMessage(role: "user", content: q)]
        chatQuickReplies = []
        searchText = ""
        withAnimation(.easeInOut(duration: 0.25)) { chatActive = true }
        advanceChat()
    }

    /// One round trip: send the history, then either show the next question
    /// or finish. A nil reply (network/API failure) finishes silently — the
    /// user gets results exactly as if the chat didn't exist.
    private func advanceChat() {
        chatLoading = true
        chatQuickReplies = []
        let turns = chatMessages.map { ClarifyService.Turn(role: $0.role, content: $0.content) }
        // Prefer the full photo context (vehicle + trade + attributes); it already
        // includes the cost details, so fall back to those only when it's absent.
        let details = photoContext ?? photoDetails
        Task {
            let reply = await ClarifyService.next(messages: turns, photoDetails: details)
            await MainActor.run {
                chatLoading = false
                switch reply {
                case .ask(let question, let quickReplies):
                    chatMessages.append(ChatMessage(role: "assistant", content: question))
                    chatQuickReplies = quickReplies
                case .done(let outcome):
                    finishChat(outcome)
                case nil:
                    finishChat(nil)
                }
            }
        }
    }

    private func sendChatReply(_ text: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, !chatLoading else { return }
        chatMessages.append(ChatMessage(role: "user", content: reply))
        searchText = ""
        advanceChat()
    }

    /// Finish the chat and open results with whatever the match resolved to. A
    /// nil outcome (network/API failure, or Skip) proceeds on the raw query —
    /// results are shown exactly as if the chat hadn't run.
    private func finishChat(_ outcome: ClarifyService.ClarifyOutcome?) {
        chatDetails = outcome?.details.isEmpty == false ? outcome?.details : nil
        chatCategory = outcome?.category ?? ""
        chatSearchTerms = outcome?.searchTerms ?? ""
        chatPhotoTerms = outcome?.photoTerms ?? ""
        chatPriceable = outcome?.priceable ?? true
        chatQuickReplies = []
        withAnimation(.easeInOut(duration: 0.25)) { chatActive = false }
        searchFocused = false
        goSearch = true
    }

    /// The chat card the input pill grows into: bubbles, quick-reply chips,
    /// and a Skip escape hatch that proceeds with what we already know.
    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Quick questions for better estimate")
                    .font(.h3)
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                Button("Skip") { finishChat(nil) }
                    .font(.h4)
                    .foregroundStyle(AppColors.accentStart)
                    .buttonStyle(.plain)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(chatMessages) { message in
                            chatBubble(message)
                        }
                        if chatLoading {
                            HStack {
                                ProgressView().tint(.white).controlSize(.small)
                                Spacer()
                            }
                            .id("chat-loading")
                        }
                    }
                }
                .frame(maxHeight: 240)
                .onChange(of: chatMessages) { _, _ in
                    withAnimation { proxy.scrollTo(chatMessages.last?.id, anchor: .bottom) }
                }
                .onChange(of: chatLoading) { _, loading in
                    if loading { withAnimation { proxy.scrollTo("chat-loading", anchor: .bottom) } }
                }
            }
            if !chatQuickReplies.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chatQuickReplies, id: \.self) { option in
                            Button(action: { sendChatReply(option) }) {
                                Text(option)
                                    .font(.h4)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .frame(height: 32)
                                    .background(Capsule().fill(AppColors.bgOverlay.opacity(0.5)))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func chatBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == "user"
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.content)
                .font(.bodyLight)
                .foregroundStyle(.white)
                .padding(16)
                .background {
                    if isUser {
                        // Customer bubble — solid accent blue (Figma 781:3216).
                        shape.fill(AppColors.accentStart)
                    } else {
                        // Assistant bubble — linear gradient #2D3047 → #3D2C00,
                        // bottom-right → top-left (0% navy at the bottom-right).
                        // Same handle direction as the chat thread's received
                        // bubble, so the two chat surfaces read as one system.
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color(hex: "#2D3047"), location: 0),
                                    .init(color: Color(hex: "#3D2C00"), location: 1),
                                ],
                                startPoint: UnitPoint(x: 1.0, y: 0.86),
                                endPoint: UnitPoint(x: 0.03, y: 0.0)
                            )
                        )
                    }
                }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func beginEditingLocation() {
        editingLocation = true
        DispatchQueue.main.async { locationFocused = true }  // focus after the field exists
    }

    private func fetchCurrentLocation() {
        editingLocation = false
        locationFocused = false
        locationStore.useCurrentLocation()
    }

    /// Auto-capture the user's location on open / when permission is granted, so a
    /// fix is ready before they pick a category. No-op if we already have one or a
    /// fix is in flight; never prompts here (only an explicit tap can prompt).
    private func autoFetchLocationIfGranted() {
        guard !locationStore.hasLocation, !locationStore.isResolving else { return }
        if locationStore.authorization == .authorizedWhenInUse
            || locationStore.authorization == .authorizedAlways {
            locationStore.useCurrentLocation()
        }
    }

    // ── Category tap → contractors are gated on having a location ──────────────
    /// Open a destination only once a location is available; otherwise remember the
    /// intent and obtain a location (GPS, prompting if needed, or manual ZIP entry).
    /// `onChange(of: coordinate)` navigates once a location lands.
    private func openIfLocated(_ destination: PendingDestination) {
        if locationStore.hasLocation {
            navigate(to: destination)
            return
        }
        pendingDestination = destination
        guard !locationStore.isResolving else { return }   // a fix is already in flight
        switch locationStore.authorization {
        case .authorizedWhenInUse, .authorizedAlways, .notDetermined:
            locationStore.useCurrentLocation()             // GPS (prompts if undetermined)
        default:                                           // .denied / .restricted
            locationFocused = true                         // can't use GPS → type a ZIP
        }
    }

    private func navigate(to destination: PendingDestination) {
        switch destination {
        case .home(let category): goSwipe = category
        case .auto(let auto):     goAuto = auto
        }
    }

    /// Open the conversations inbox when a `brightglow://chat` deep link is
    /// pending (set by ChatRouter). Consumes the flag so it fires once.
    private func consumePendingChatDeepLink() {
        guard chatRouter.openInboxRequested else { return }
        chatRouter.openInboxRequested = false
        showChat = true
    }

    /// Opens the inbox from the header icon. The dot isn't cleared here — it
    /// stays until the unread threads themselves are opened, then refreshes off
    /// per-thread read state when the landing reappears (`refreshChatUnread`).
    private func openChat() {
        showChat = true
    }

    /// Best-effort refresh of the header unread dot when the landing appears.
    private func refreshChatUnread() {
        Task {
            let unread = await ChatService.hasUnread()
            await MainActor.run { hasUnreadChat = unread }
        }
    }

    /// Decode the picker's selected items. A single picked photo opens the same
    /// full-screen draw-over canvas a camera capture does (circle the problem,
    /// describe, submit routes by the photo); picking several keeps the
    /// thumbnail strip, since draw-over is a one-photo flow.
    private func loadPickedImages(_ items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            await MainActor.run {
                if images.count == 1, pickedImages.isEmpty, let image = images.first {
                    pickedItems = []
                    camera.present(image)
                } else {
                    pickedImages = images
                }
            }
        }
    }

    /// Remove one thumbnail and keep the picker selection in sync.
    /// One 56pt rounded thumbnail with an ✕ to detach it.
    @ViewBuilder
    private func thumbnail(_ image: UIImage, onRemove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding(2)
            }
        }
    }

    private func removePickedImage(at index: Int) {
        guard pickedImages.indices.contains(index) else { return }
        pickedImages.remove(at: index)
        if pickedItems.indices.contains(index) {
            pickedItems.remove(at: index)
        }
    }

    /// Detach a captured photo. When the last one goes, drop its derived
    /// cost attributes too so a stale estimate hint can't ride along.
    private func removeAttachedImage(at index: Int) {
        guard attachedImages.indices.contains(index) else { return }
        attachedImages.remove(at: index)
        if attachedImages.isEmpty { photoDetails = nil; photoContext = nil }
    }

    /// Compose what the clarify chat should know about the user's photo, so it
    /// won't ask what the image already answers. Combines the detected vehicle
    /// type (the signal that stops the "car or motorcycle?" question), the
    /// detected trade/service, and any visible cost attributes. Nil when the
    /// classifier recognised nothing.
    private static func clarifyPhotoContext(
        match: TradeMatch?, vehicle: VehicleFilter?, details: String?
    ) -> String? {
        var parts: [String] = []
        if let vehicle { parts.append(vehicle == .moto ? "a motorcycle" : "a car or truck") }
        if let match { parts.append(match.label.lowercased()) }
        if let details = details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
            parts.append(details)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
