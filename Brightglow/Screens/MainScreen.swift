import SwiftUI
import CoreLocation
import PhotosUI

/// A contractor destination awaiting a resolved location before it can open.
private enum PendingDestination {
    case home(Category)
    case auto(AutoCategory)
}

struct MainScreen: View {
    @StateObject private var camera = CameraViewModel()
    @StateObject private var locationStore = LocationStore()
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
    @State private var searchText = ""
    @State private var locationQuery = ""
    /// True while the user is editing the location (typing a ZIP) — kept separate
    /// from @FocusState so the "Current location" CTA shows reliably on tap.
    @State private var editingLocation = false
    /// Destination the user tapped before a location was available; navigates once
    /// a location resolves. Contractors are never shown without a location.
    @State private var pendingDestination: PendingDestination? = nil
    @State private var drawnPaths: [DrawnPath] = []
    @State private var showProfile = false
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
                            Button(action: { showProfile = true }) {
                                // Plain glyph, no background — same flat style as the
                                // location pin (white, line icon).
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 24, weight: .regular))
                                    .foregroundStyle(.white)
                                    .iconTapTarget()
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(alignment: .top) { BlurredHeaderBackground() }
                        Spacer()
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(!searchFocused)

                    // ── Shutter button + hint — always shown on the landing chooser
                    // once the camera is authorized (it sits 16pt above the fixed
                    // categories sheet). Before access is granted the CameraScreen's
                    // centered "tap to grant" button is the CTA instead.
                    if selectedVertical == nil && camera.isAuthorized {
                        VStack(spacing: 0) {
                            Spacer()
                            HintPill(text: "Take a picture and explain your task for a smart estimate")
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
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
                            .padding(.bottom, shutterPad)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: selectedVertical)
                        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: sheetDetent)
                        .animation(.easeOut(duration: 0.25), value: searchFocused)
                        .allowsHitTesting(!searchFocused)
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
                    .allowsHitTesting(!searchFocused)

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
                    // is focused (it expands and the fade would float mid-screen)
                    if !searchFocused {
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

                    // ── Search / input bar
                    VStack(spacing: 10) {
                      // Picked-photo thumbnails — horizontal strip above the field
                      if !pickedImages.isEmpty {
                          ScrollView(.horizontal, showsIndicators: false) {
                              HStack(spacing: 8) {
                                  ForEach(Array(pickedImages.enumerated()), id: \.offset) { index, image in
                                      ZStack(alignment: .topTrailing) {
                                          Image(uiImage: image)
                                              .resizable()
                                              .scaledToFill()
                                              .frame(width: 56, height: 56)
                                              .clipShape(RoundedRectangle(cornerRadius: 12))
                                          Button {
                                              removePickedImage(at: index)
                                          } label: {
                                              Image(systemName: "xmark.circle.fill")
                                                  .font(.system(size: 18))
                                                  .foregroundStyle(.white, .black.opacity(0.5))
                                                  .padding(2)
                                          }
                                      }
                                  }
                              }
                              .padding(.horizontal, 4)
                          }
                          .frame(height: 56)
                      }
                      HStack(alignment: .center, spacing: 12) {
                        TextField("What you need help with?", text: $searchText, axis: .vertical)
                            .font(.bodyLight)
                            .foregroundStyle(.white)
                            .tint(AppColors.accentStart)
                            .focused($searchFocused)
                            .lineLimit(1...5)
                            .submitLabel(.search)
                            .onSubmit {
                                let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !q.isEmpty else { return }
                                submittedQuery = q
                                searchFocused = false
                                goSearch = true
                            }
                        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            HStack(spacing: 0) {
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
                                Image(systemName: "mic")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .iconTapTarget()
                            }
                        } else {
                            // Send CTA — right-pointing white arrow on blue background
                            Button(action: {
                                let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !q.isEmpty else { return }
                                submittedQuery = q
                                searchFocused = false
                                goSearch = true
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
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            if value.translation.height > 20 && searchFocused {
                                searchFocused = false
                            }
                        },
                    including: searchFocused ? .all : .none
                )
                .navigationBarHidden(true)
                // Camera viewfinder is always exposed above the fixed sheet, so
                // resume the session whenever the landing reappears. Also grab the
                // user's location automatically when permission is already granted.
                .onAppear {
                    camera.activateIfNeeded()
                    autoFetchLocationIfGranted()
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
                                         presetCoordinate: locationStore.coordinate)
                }
                .navigationDestination(isPresented: $goSearch) {
                    ContractorListScreen(searchQuery: submittedQuery,
                                         presetCoordinate: locationStore.coordinate)
                }
                .navigationDestination(isPresented: Binding(
                    get: { goAuto != nil },
                    set: { if !$0 { goAuto = nil } }
                )) {
                    ContractorListScreen(category: goAuto?.name ?? "",
                                         searchQuery: goAuto?.searchQuery ?? "",
                                         presetCoordinate: locationStore.coordinate)
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
                    },
                    onSubmit: { word in
                        // Dismiss the capture cover, then open the matching results:
                        // typed word wins (free-text search); else route by the
                        // photo's detected trade — auto → auto providers, home →
                        // the home category deck; else a mixed search.
                        let q = word.trimmingCharacters(in: .whitespacesAndNewlines)
                        let detected = camera.detectedMatch
                        camera.retake()
                        drawnPaths = []
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if !q.isEmpty {
                                submittedQuery = q
                                goSearch = true
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
                    prefill: camera.detectedMatch?.label ?? "",
                    categorySuggestions: autoSuggestionsActive
                        ? autoCategoryItems.map(\.name)
                        : Category.allCases.map(\.rawValue),
                    objects: camera.detectedObjects,
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
    /// True when the captured photo was recognised as an Auto & moto subject —
    /// drives the in-capture category carousel to suggest auto services.
    private var autoSuggestionsActive: Bool {
        if case .auto = camera.detectedMatch { return true }
        return false
    }

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

    /// Decode the picker's selected items into UIImages for the thumbnail strip.
    private func loadPickedImages(_ items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            await MainActor.run { pickedImages = images }
        }
    }

    /// Remove one thumbnail and keep the picker selection in sync.
    private func removePickedImage(at index: Int) {
        guard pickedImages.indices.contains(index) else { return }
        pickedImages.remove(at: index)
        if pickedItems.indices.contains(index) {
            pickedItems.remove(at: index)
        }
    }
}
