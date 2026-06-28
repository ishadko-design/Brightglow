import SwiftUI
import CoreLocation
import PhotosUI

struct MainScreen: View {
    @StateObject private var camera = CameraViewModel()
    @StateObject private var locationStore = LocationStore()
    @State private var sheetDetent: SheetDetent = .full
    @State private var sheetScrolledToTop = true
    @State private var goSwipe: Category? = nil
    @State private var goSearch = false
    @State private var submittedQuery = ""
    @State private var searchText = ""
    @State private var locationQuery = ""
    /// True while the user is editing the location (typing a ZIP) — kept separate
    /// from @FocusState so the "Current location" CTA shows reliably on tap.
    @State private var editingLocation = false
    /// Category the user tapped before a location was available; navigates once resolved.
    @State private var pendingCategory: Category? = nil
    @State private var drawnPaths: [DrawnPath] = []
    @State private var showCameraHint = false
    @State private var showProfile = false
    /// Native photo-picker selection (raw items) and the decoded images shown
    /// as thumbnails above the input bar.
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pickedImages: [UIImage] = []
    /// Measured height of the input pill — drives the shutter's clearance so it
    /// always sits ≥16pt above the bar, even when it grows (thumbnails, multi-line).
    @State private var inputBarHeight: CGFloat = 60
    @FocusState private var searchFocused: Bool
    @FocusState private var locationFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Sheet nearly full-screen in default state; CTA only appears when collapsed
                let midHeight: CGFloat = geo.size.height - 100
                let collapsedHeight: CGFloat = 180
                let headerInset: CGFloat = 76   // 60pt header (44 + 8/8 padding) + 16pt gap to the sheet
                // True whenever a text field (search OR the location/ZIP field) has
                // raised the keyboard — both should dock the input bar to it.
                let keyboardActive = searchFocused || locationFocused
                // 16pt above the sheet when keyboard is hidden;
                // 16pt above the (measured) input bar when keyboard is shown:
                // bar sits 16pt above the keyboard, so clear = 16 + barHeight + 16.
                let shutterPad: CGFloat = keyboardActive ? (inputBarHeight + 16 + 16) : (collapsedHeight + 16)

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
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .iconTapTarget()
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(alignment: .top) { BlurredHeaderBackground() }
                        Spacer()
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(!searchFocused)

                    // ── Shutter button + hint — only once the camera is authorized
                    // and the sheet is collapsed. Before access is granted the
                    // CameraScreen's centered "tap to grant" button is the CTA.
                    if sheetDetent == .collapsed && camera.isAuthorized {
                        VStack(spacing: 0) {
                            Spacer()
                            HintPill(text: "Take a picture and explain your task for a smart estimate")
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                                .opacity(showCameraHint ? 1 : 0)
                                .animation(.easeInOut(duration: 0.4), value: showCameraHint)
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
                        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: sheetDetent)
                        .animation(.easeOut(duration: 0.25), value: searchFocused)
                        .animation(.easeInOut(duration: 0.4), value: showCameraHint)
                        .allowsHitTesting(!searchFocused)
                    }

                    // ── Draggable categories sheet
                    BottomSheet(
                        detent: $sheetDetent,
                        contentIsAtTop: sheetScrolledToTop,
                        collapsedHeight: collapsedHeight,
                        midHeight: midHeight,
                        fullTopInset: headerInset
                    ) {
                        CategoriesSheet(
                            onCategoryTap: handleCategoryTap,
                            onProfileTap: {},
                            isScrolledToTop: $sheetScrolledToTop
                        )
                    }
                    .allowsHitTesting(!searchFocused)

                    // ── Solid fill behind the keyboard ───────────────────────────
                    // The gradient/search bar are pushed up with the keyboard, so
                    // without this their bg ends at the keyboard's rounded top and
                    // visibly "stacks". This strip ignores the keyboard inset, so it
                    // stays pinned to the screen bottom and the bg continues behind
                    // the (translucent) keyboard — no seam at the rounded corners.
                    if keyboardActive {
                        AppColors.bg
                            .frame(height: 400)
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
                .onChange(of: sheetDetent) { _, newDetent in
                    if newDetent == .collapsed {
                        camera.activateIfNeeded()
                        showCameraHint = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { showCameraHint = false }
                        }
                    } else {
                        showCameraHint = false
                    }
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
                // Once a location resolves (GPS fix or manual ZIP/city), continue
                // to the category the user tapped while it was still missing.
                .onChange(of: locationStore.coordinate?.latitude) { _, _ in
                    if locationStore.coordinate != nil, let pending = pendingCategory {
                        pendingCategory = nil
                        goSwipe = pending
                    }
                }
                // If they deny the system prompt, fall back to manual entry.
                .onChange(of: locationStore.authorization) { _, status in
                    if (status == .denied || status == .restricted), pendingCategory != nil {
                        locationFocused = true
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
                        // Dismiss the capture cover, then open the matching card deck:
                        // typed word wins; else the photo's detected category; else mixed.
                        let q = word.trimmingCharacters(in: .whitespacesAndNewlines)
                        let detected = camera.detectedCategory
                        camera.retake()
                        drawnPaths = []
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if !q.isEmpty {
                                submittedQuery = q
                                goSearch = true
                            } else if let cat = detected {
                                goSwipe = cat
                            } else {
                                submittedQuery = ""
                                goSearch = true
                            }
                        }
                    },
                    prefill: camera.detectedCategory?.rawValue ?? "",
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
                    .frame(width: 20, height: 20)
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

    // ── Category tap → ensure we have a location first ────────────────────────
    private func handleCategoryTap(_ category: Category) {
        // A location lookup is in flight (e.g. a city was just typed) — wait for
        // the new coordinate before opening results, so we don't show contractors
        // for the previous location. onChange(of: coordinate) navigates once it lands.
        if locationStore.isResolving {
            pendingCategory = category
            return
        }
        switch locationStore.authorization {
        case _ where locationStore.hasLocation:
            goSwipe = category                              // already resolved
        case .authorizedWhenInUse, .authorizedAlways:
            goSwipe = category                              // permitted; gallery resolves GPS
        case .denied, .restricted:
            pendingCategory = category                      // can't use GPS → type a location
            locationFocused = true
        default:                                            // .notDetermined
            pendingCategory = category
            locationStore.useCurrentLocation()              // system prompt, then navigate
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
