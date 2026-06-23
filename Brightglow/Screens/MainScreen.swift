import SwiftUI

struct MainScreen: View {
    @StateObject private var camera = CameraViewModel()
    @State private var sheetDetent: SheetDetent = .full
    @State private var sheetScrolledToTop = true
    @State private var goSwipe: Category? = nil
    @State private var goSearch = false
    @State private var submittedQuery = ""
    @State private var searchText = ""
    @State private var drawnPaths: [DrawnPath] = []
    @State private var showCameraHint = false
    @State private var showProfile = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                // Sheet nearly full-screen in default state; CTA only appears when collapsed
                let midHeight: CGFloat = geo.size.height - 100
                let collapsedHeight: CGFloat = 180
                let headerInset: CGFloat = 52   // 44pt header + 8pt gap so the sheet doesn't touch the icon
                // 16pt above the sheet when keyboard is hidden;
                // 16pt above the input bar (60pt tall, 8pt bottom padding) when keyboard is shown.
                let shutterPad: CGFloat = searchFocused ? (60 + 8 + 16) : (collapsedHeight + 16)

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

                    // ── Profile icon
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button(action: { showProfile = true }) {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .iconTapTarget()
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .padding(.trailing, 16)
                        }
                        .frame(height: 54)
                        Spacer()
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(!searchFocused)

                    // ── Shutter button + hint — visible when sheet is collapsed
                    if sheetDetent == .collapsed {
                        VStack(spacing: 0) {
                            Spacer()
                            HintPill(text: "Take a picture for smart estimate")
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
                            onCategoryTap: { category in goSwipe = category },
                            onProfileTap: {},
                            isScrolledToTop: $sheetScrolledToTop
                        )
                    }
                    .allowsHitTesting(!searchFocused)

                    // ── Gradient fade into search bar — hidden when keyboard is active
                    // (keyboard pushes the ZStack up, making the gradient float mid-screen)
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
                    HStack(alignment: .center, spacing: 12) {
                        TextField("Describe what you need…", text: $searchText, axis: .vertical)
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
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .iconTapTarget()
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
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
                    .padding(.bottom, searchFocused ? 8 : 34)
                    .animation(.easeOut(duration: 0.25), value: searchFocused)
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
                    SwipeScreen(category: goSwipe?.rawValue ?? "")
                }
                .navigationDestination(isPresented: $goSearch) {
                    SwipeScreen(searchQuery: submittedQuery)
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
}
