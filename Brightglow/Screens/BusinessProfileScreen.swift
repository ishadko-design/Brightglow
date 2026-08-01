import SwiftUI
import PhotosUI
import Supabase
import UniformTypeIdentifiers

/// The business's "Settings" — the page customers see, pared down to the essentials
/// (Figma 1096:5699): logo + name + description, the work photos, and the services
/// with indicative price ranges. Reached from the dashboard's gear, its "Set up"
/// card, and the post-reply nudge. Reads/writes go direct to Supabase/Storage under
/// RLS (`BusinessService`).
///
/// Deliberately narrower than the web portal: phone, website, service area, license
/// and the licensed/insured flag are left to the web editor and stay untouched in
/// the DB — the native flow optimizes for the few fields that win more work.
struct BusinessProfileScreen: View {
    /// The place whose page is being edited. Comes from the dashboard's selection;
    /// nil only in an unexpected state (no business), which shows an empty guard.
    let placeId: String?

    /// True when rendered as the dashboard's "Settings" tab rather than pushed on
    /// its own. The parent already draws the header and the tab pill, so this
    /// screen drops its own header and back gesture and contributes only the form.
    var embedded = false

    @EnvironmentObject private var store: BusinessStore
    @Environment(\.dismiss) private var dismiss

    @State private var working = BusinessService.BusinessProfile(placeIdOnly: "")
    @State private var original = BusinessService.BusinessProfile(placeIdOnly: "")
    @State private var loaded = false

    @State private var logoItem: PhotosPickerItem?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var uploadMsg: String?

    /// The unified, ordered photo set shown in the manager (uploads + Google +
    /// website). Mirrors `working.curatedPhotos` once the owner touches it; before
    /// that it's seeded from the live sources so the manager opens populated.
    @State private var curated: [BusinessService.CuratedPhoto] = []
    @State private var curatedLoaded = false
    @State private var loadingCurated = false
    /// The photo currently under a drag, so its tile can show a drop-target box.
    @State private var dropTargetID: String?

    /// Drives the full-screen "View profile" preview — the same page customers see.
    @State private var showPreview = false

    @State private var saving = false
    /// Set only when a write actually failed. With no Save button left, this is
    /// the sole signal that something didn't persist — so it must never be silent.
    @State private var errorMessage: String?
    @State private var autosaveTask: Task<Void, Never>?

    private var dirty: Bool { loaded && working != original }

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                if !embedded { header }
                if placeId == nil {
                    Spacer()
                    Text("No business selected.")
                        .font(.bodyLight).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                } else if !loaded {
                    Spacer(); ProgressView().tint(.white); Spacer()
                } else {
                    form
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack(!embedded)
        .preferredColorScheme(.dark)
        .task { await load(); await loadCuratedPhotos() }
        .onChange(of: working) { _, _ in scheduleAutosave() }
        .onDisappear { flushPendingSave() }
        .onChange(of: logoItem) { _, item in Task { await uploadLogo(item) } }
        .onChange(of: photoItems) { _, items in Task { await uploadPhotos(items) } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Text("Settings")
                .font(.h2).foregroundStyle(.white)
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.top, 8)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if let errorMessage { errorBanner(errorMessage) }
                profileSection
                servicesSection
                viewProfileButton
                AccountFooter()
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Profile")
            card {
                VStack(alignment: .leading, spacing: 24) {
                    // Logo
                    HStack(spacing: 16) {
                        logoPreview
                        VStack(alignment: .leading, spacing: 12) {
                            PhotosPicker(selection: $logoItem, matching: .images, photoLibrary: .shared()) {
                                Text("Upload logo")
                                    .font(.h4).foregroundStyle(.white)
                                    .padding(.horizontal, 16).frame(height: 32)
                                    .secondaryButtonBackground()
                            }
                            Text("Square works best. PNG or JPG.")
                                .font(.bodySmall).foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer(minLength: 0)
                    }

                    field("Business name") {
                        fieldInput("Local plumber", text: strBinding(\.displayName))
                    }
                    field("Description") {
                        fieldInput("Tell people what your business does",
                                   text: strBinding(\.about), axis: .vertical)
                    }

                    // Credentials — self-declared trust signals shown to customers.
                    HStack(spacing: 12) {
                        checkbox("Licensed", isOn: boolBinding(\.licensed))
                        checkbox("Insured", isOn: boolBinding(\.insured))
                    }

                    // Pictures — the curated set the customer sees: uploaded photos
                    // plus the ones pulled from Google and the business's website,
                    // all reorderable and removable.
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pictures").font(.h4).foregroundStyle(.white)
                            Text("Drag to reorder. Remove any you don't want — including ones we pulled from Google and your website.")
                                .font(.bodySmall).foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        curatedStrip
                        if let uploadMsg {
                            Text(uploadMsg).font(.bodySmall).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    /// Opens the customer-facing page — logo, name, description, and the photos a
    /// customer would see (the uploaded ones, plus the business's Google/website
    /// work photos) — so the owner can check how their listing reads before a lead
    /// ever sees it. Any unsaved edit is flushed first so the preview is current.
    private var viewProfileButton: some View {
        Button {
            Task {
                if dirty { await save() }
                showPreview = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 15, weight: .semibold))
                Text("View profile")
                    .font(.h4)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
        .buttonStyle(.secondary)
        .padding(.horizontal, 16)
        .fullScreenCover(isPresented: $showPreview) {
            ProfilePreviewScreen(profile: working)
        }
    }

    private var logoPreview: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(AppColors.fillSubtle)
            .frame(width: 104, height: 104)
            .overlay {
                if let path = working.logoPath, let url = BusinessService.publicURL(path) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Image(systemName: "building.2").foregroundStyle(.white.opacity(0.4))
                        }
                    }
                } else {
                    Image(systemName: "building.2")
                        .font(.system(size: 32)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // ✕ remove — only when a logo is set. Clears logoPath, which the
            // encoder writes as null on the next autosave, restoring the
            // placeholder. Mirrors the photo tiles' remove control.
            .overlay(alignment: .topTrailing) {
                if !(working.logoPath ?? "").isEmpty {
                    Button(action: removeLogo) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
    }

    /// Horizontal strip of the curated photos — each draggable to reorder and
    /// removable — ending in an add tile. Scraped photos (Google / website) carry a
    /// small source tag so the owner knows where each came from.
    private var curatedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if loadingCurated && curated.isEmpty {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AppColors.fillSubtle)
                        .frame(width: 112, height: 136)
                        .overlay { ProgressView().tint(.white) }
                }
                ForEach(curated) { photo in
                    // The light-gray drop slot opens as a real gap BEFORE the tile a
                    // drag is hovering, so the photo visibly slots between two others.
                    if dropTargetID == photo.id {
                        dropPlaceholder
                    }
                    curatedCell(photo)
                }
                addPhotoTile
            }
            .padding(.vertical, 2)
            .animation(.easeInOut(duration: 0.18), value: curated)
            .animation(.easeInOut(duration: 0.18), value: dropTargetID)
        }
    }

    /// The gray "drop here" slot — a same-shape, same-size gap that appears between
    /// tiles while a drag hovers, showing where the photo will land.
    private var dropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(0.14))
            .frame(width: 112, height: 136)
    }

    // A photo tile. The drag catcher (`.onDrag`) covers only the LOWER part of the
    // tile, leaving a drag-free band at the top where the ✕ lives — that's the only
    // reliable way to keep whole-ish-tile drag while the ✕ still taps, since the
    // UIKit drag interaction swallows every touch inside its own bounds. The whole
    // tile is still a drop TARGET (that's passive, it doesn't eat taps).
    private func curatedCell(_ photo: BusinessService.CuratedPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            curatedThumb(photo)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Drag source — bottom region only (top 44pt left free for the ✕).
            VStack(spacing: 0) {
                Color.clear.frame(height: 44).allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .onDrag {
                        NSItemProvider(object: photo.id as NSString)
                    } preview: {
                        curatedThumb(photo)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .opacity(0.9)
                    }
            }

            // ✕ delete — a normal Button, sitting in the drag-free top band, so its
            // tap is never contested by the drag interaction.
            Button(action: { removeCurated(photo) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(6)

            // Where the photo came from — only for scraped ones; uploads need none.
            if photo.source != .upload {
                Text(photo.source == .google ? "Google" : "Web")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 112, height: 136)
        .onDrop(of: [.text], isTargeted: Binding(
            get: { dropTargetID == photo.id },
            set: { dropTargetID = $0 ? photo.id : (dropTargetID == photo.id ? nil : dropTargetID) }
        )) { providers in
            dropTargetID = nil
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let draggedID = obj as? String else { return }
                Task { @MainActor in moveCurated(fromID: draggedID, beforeID: photo.id) }
            }
            return true
        }
    }

    private func curatedThumb(_ photo: BusinessService.CuratedPhoto) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(AppColors.fillSubtle)
            .frame(width: 112, height: 136)
            .overlay {
                if let s = BusinessService.resolvedPhotoURL(photo), let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            .frame(width: 112, height: 136)
            .clipped()
    }

    private var addPhotoTile: some View {
        PhotosPicker(selection: $photoItems, maxSelectionCount: 10,
                     matching: .images, photoLibrary: .shared()) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppColors.bgOverlay)
                .frame(width: 112, height: 136)
                .overlay {
                    if uploading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .disabled(uploading)
    }

    // MARK: Services

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Typical services")
                Text("Get more leads with transparent price ranges.")
                    .font(.bodySmall).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 16)
            }

            ForEach($working.services) { $svc in
                card {
                    ServiceRowEditor(service: $svc) { remove(svc) }
                }
            }

            Button {
                working.services.append(BusinessService.Service())
            } label: {
                Text("Add service")
                    .font(.h4).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40)
                    .background(AppColors.ctaPrimary, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
    }

    /// The one piece of save UI left: shown only when a write actually failed.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.starFilled)
            Text(message)
                .font(.bodySmall).foregroundStyle(.white)
            Spacer()
            Button(action: { Task { await save() } }) {
                Text("Retry")
                    .font(.h4).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 32)
                    .secondaryButtonBackground()
            }
            .buttonStyle(.plain)
            .disabled(saving)
        }
        .padding(16)
        .background(AppColors.cardSurface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: - Autosave

    /// Edits persist on their own — there is no Save button (Figma 1096:5699 has
    /// none). Every keystroke would be a write, so a change schedules a save and
    /// resets the timer; only the pause at the end actually hits the network.
    private func scheduleAutosave() {
        guard loaded, dirty else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    /// Leaving the screen inside the debounce window must not lose the edit, so
    /// flush immediately. This deliberately does NOT touch view state — the view
    /// is going away, and mutating `@State` from here would be a write to a dead
    /// view. The store still gets the update so the dashboard reflects it.
    private func flushPendingSave() {
        guard loaded, dirty else { return }
        autosaveTask?.cancel()
        var toSave = working
        toSave.normalizeForSave()
        let store = self.store
        Task {
            try? await BusinessService.saveProfile(toSave)
            await MainActor.run { store.applySavedProfile(toSave) }
        }
    }

    // MARK: - Data

    private func load() async {
        guard let placeId, !loaded else { return }
        // Prefer the copy the store already resolved for this place.
        var p = store.selectedPlaceId == placeId ? store.profile : nil
        if p == nil { p = try? await BusinessService.profile(placeId: placeId) }
        if p == nil, let biz = store.businesses.first(where: { $0.placeId == placeId }) {
            p = BusinessService.BusinessProfile(seededFrom: biz)
        }
        var resolved = p ?? BusinessService.BusinessProfile(placeIdOnly: placeId)
        // Open one empty service block by default so the pricing section is
        // discoverable rather than a bare "Add service" button (mirrors the web
        // portal). An unnamed row is dropped by normalizeForSave, so it never
        // persists; seeding before both copies keeps it out of the dirty check.
        if resolved.services.isEmpty {
            resolved.services.append(BusinessService.Service())
        }
        working = resolved
        original = resolved
        loaded = true
    }

    private func save() async {
        saving = true
        var toSave = working
        toSave.normalizeForSave()
        do {
            try await BusinessService.saveProfile(toSave)
            // Only `original` advances — reassigning `working` mid-typing would
            // stomp keystrokes made while the request was in flight.
            original = toSave
            store.applySavedProfile(toSave)
            errorMessage = nil
        } catch {
            #if DEBUG
            print("🏢 profile save failed — \(error)")
            #endif
            // A successful autosave says nothing; a failed one has to, since
            // there's no Save button left to retry from.
            errorMessage = "Couldn't save your changes."
        }
        saving = false
    }

    // MARK: - Uploads

    private func uploadLogo(_ item: PhotosPickerItem?) async {
        guard let item, let placeId, let data = try? await item.loadTransferable(type: Data.self) else { return }
        do {
            let path = try await BusinessService.uploadImage(
                data, contentType: contentType(for: data), placeId: placeId, prefix: "logo")
            working.logoPath = path
        } catch {
            uploadMsg = "Logo upload failed."
        }
        logoItem = nil
    }

    /// Clears the logo. Storage object is left in place (same as photo removal),
    /// since the record of uploaded objects lives in `photos`/storage and the
    /// gallery keys off `logoPath` being null.
    private func removeLogo() {
        working.logoPath = nil
        logoItem = nil
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, let placeId else { return }
        uploading = true; uploadMsg = nil
        var added = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                let path = try await BusinessService.uploadImage(
                    data, contentType: contentType(for: data), placeId: placeId)
                // New uploads lead the strip — the owner's freshest work first.
                curated.insert(.init(source: .upload, ref: path), at: 0)
                added += 1
            } catch {
                #if DEBUG
                print("🏢 photo upload failed — \(error)")
                #endif
            }
        }
        if added > 0 { commitCurated() }
        uploading = false
        photoItems = []
        uploadMsg = added > 0 ? nil : "Upload failed."
    }

    // MARK: - Curated photos

    /// Populate the manager. If the business already curated its photos, that saved
    /// order is authoritative. Otherwise seed from the live sources the gallery
    /// would auto-merge — uploads (trusted) plus the business's Google and website
    /// photos, screened the same way — so the manager opens showing everything the
    /// customer currently sees, ready to reorder or prune. Nothing is persisted
    /// until the owner actually changes something (see `commitCurated`).
    private func loadCuratedPhotos() async {
        guard let placeId, !curatedLoaded else { return }
        curatedLoaded = true
        if let saved = working.curatedPhotos {
            curated = saved
            return
        }
        loadingCurated = true
        defer { loadingCurated = false }

        var list: [BusinessService.CuratedPhoto] =
            working.photos.map { .init(source: .upload, ref: $0) }

        // The business's own Google + website photos, screened like the gallery so
        // logos / storefronts / junk don't seed the strip.
        async let websiteURLs = BusinessPhotoService.fetch(placeId: placeId, website: working.website)
        async let details = PlacesService.fetchDetails(placeId: placeId)
        let scraped = (await websiteURLs) + ((await details)?.photos ?? [])
        if !scraped.isEmpty {
            let screened = await PhotoFilter.screen(scraped, limit: 30, scanLimit: scraped.count)
            for p in screened {
                // A Places media URL → store its stable name as a google ref; any
                // other URL is a website photo, stored verbatim.
                if let name = PlacesService.googlePhotoName(fromMediaURL: p.url) {
                    list.append(.init(source: .google, ref: name))
                } else {
                    list.append(.init(source: .website, ref: p.url))
                }
            }
        }
        // The view may have changed selection while we fetched.
        guard placeId == self.placeId else { return }
        curated = list
    }

    /// Persist the current curated set. Writing `curatedPhotos` makes it
    /// authoritative for the gallery; keeping `photos` in step preserves the record
    /// of which uploaded Storage objects the page still references.
    private func commitCurated() {
        working.curatedPhotos = curated
        working.photos = curated.filter { $0.source == .upload }.map(\.ref)
    }

    private func removeCurated(_ photo: BusinessService.CuratedPhoto) {
        curated.removeAll { $0.id == photo.id }
        commitCurated()
    }

    /// Reorder by dropping the dragged tile immediately before the target tile.
    private func moveCurated(fromID: String, beforeID: String) {
        guard fromID != beforeID,
              let from = curated.firstIndex(where: { $0.id == fromID }) else { return }
        let item = curated.remove(at: from)
        let insertAt = curated.firstIndex(where: { $0.id == beforeID }) ?? curated.count
        curated.insert(item, at: insertAt)
        commitCurated()
    }

    private func contentType(for data: Data) -> String {
        BusinessService.imageContentType(for: data)
    }

    // MARK: - Mutations

    private func remove(_ svc: BusinessService.Service) {
        working.services.removeAll { $0.id == svc.id }
        // There's always one open service row — deleting the last one leaves a
        // fresh blank rather than an empty section with nothing to type into.
        if working.services.isEmpty {
            working.services.append(BusinessService.Service())
        }
    }

    // MARK: - Field bindings

    /// Text binding onto an optional String column (nil shows as empty).
    private func strBinding(_ key: WritableKeyPath<BusinessService.BusinessProfile, String?>) -> Binding<String> {
        Binding(get: { working[keyPath: key] ?? "" },
                set: { working[keyPath: key] = $0 })
    }

    private func boolBinding(_ key: WritableKeyPath<BusinessService.BusinessProfile, Bool>) -> Binding<Bool> {
        Binding(get: { working[keyPath: key] }, set: { working[keyPath: key] = $0 })
    }

    // MARK: - Small view helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.h2).foregroundStyle(.white)
            .padding(.horizontal, 16)
    }

    /// The rounded translucent card the Settings sections sit on.
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Figma: card surface is gray05 at radius 32. This was gray10/28 —
            // twice as bright as the design.
            .background(AppColors.cardSurface,
                        in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(.horizontal, 16)
    }

    /// A tappable checkbox row — a filled accent square with a check when on, an
    /// empty outlined square when off — plus its label. Fills its half of the row.
    private func checkbox(_ label: String, isOn: Binding<Bool>) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn.wrappedValue ? AppColors.ctaPrimary : Color.clear)
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isOn.wrappedValue ? Color.clear : Color.white.opacity(0.3), lineWidth: 1.5)
                    )
                    .overlay {
                        if isOn.wrappedValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text(label).font(.bodyLight).foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.h4).foregroundStyle(.white)
            content()
        }
    }

    private func fieldInput(_ placeholder: String, text: Binding<String>,
                            keyboard: UIKeyboardType = .default,
                            axis: Axis = .horizontal) -> some View {
        TextField("", text: text,
                  prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)),
                  axis: axis)
            .font(.bodyLight).foregroundStyle(.white)
            .tint(AppColors.accentStart)
            .keyboardType(keyboard)
            .lineLimit(axis == .vertical ? 5 : 1)
            .padding(.horizontal, 20).padding(.vertical, axis == .vertical ? 16 : 0)
            .frame(minHeight: 60, alignment: axis == .vertical ? .top : .center)
            .inputFieldSurface()
    }
}

/// The one text-field treatment in the app, matching the main search input on
/// MainScreen (same `bgSecondary` fill, 1.5pt `gray20` border, 32pt radius) so the
/// business editor reads as the same product rather than a separate form. Applied
/// to every field here — profile fields and the service name/price inputs.
private extension View {
    func inputFieldSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return self
            .background(AppColors.bgOverlay, in: shape)
            .overlay(shape.stroke(AppColors.searchBorder, lineWidth: 1.5))
    }
}

/// The owner-facing preview of the customer page. Reuses the exact consumer
/// gallery (`ContractorGalleryScreen`) in `previewMode`, so what the owner sees
/// is what a customer sees — the uploaded photos leading, then the business's
/// Google/website work photos and reviews — minus the Call / Request-quote
/// footer and view tracking.
///
/// It resolves the live Google details for the place (photos, rating, reviews);
/// if that's unavailable (offline, or the key isn't configured), it falls back
/// to a card built from the saved profile so the uploaded photos still preview.
private struct ProfilePreviewScreen: View {
    let profile: BusinessService.BusinessProfile

    @Environment(\.dismiss) private var dismiss
    @State private var contractor: Contractor?
    @State private var resolved = false

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            if let contractor {
                ContractorGalleryScreen(
                    // No search context — order photos as-is; the uploaded ones lead.
                    preloadedContractors: [contractor],
                    // Open with the info sheet expanded so the owner immediately sees
                    // their description, services, and credentials — not just a peek.
                    startReviewsExpanded: true,
                    previewMode: true,
                    previewProfile: profile
                )
            } else if resolved {
                unavailable
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Live Google details give the real photo pool + reviews; fall back to
            // the saved profile so the preview still works offline / unconfigured.
            contractor = await PlacesService.fetchDetails(placeId: profile.placeId)
                ?? fallbackContractor()
            resolved = true
        }
    }

    // Shown only if we can't build any card at all (no place id) — the preview has
    // nothing to render, so offer a way back rather than a blank screen.
    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text("Preview unavailable")
                .font(.h3).foregroundStyle(.white)
            Button("Close") { dismiss() }
                .font(.h4).foregroundStyle(.white)
                .padding(.top, 4)
        }
    }

    /// A card from the saved profile alone. Photos are left empty here — the
    /// gallery merges the uploaded photos itself (from `business_profiles`), so
    /// they lead whether or not Google details resolved.
    private func fallbackContractor() -> Contractor {
        let name = (profile.displayName?.isEmpty == false) ? profile.displayName! : "Your business"
        return Contractor(
            id: profile.placeId,
            name: name,
            category: [],
            city: "",
            rating: 0,
            reviewCount: 0,
            responseTime: .normal,
            yearsActive: 0,
            photos: [],
            priceTiers: [],
            phone: profile.phone,
            website: profile.website,
            licenseNumber: profile.licenseNumber,
            isVerified: true,
            reviews: []
        )
    }
}

/// One editable service line, in its own card: name, then a min/max price row and
/// a Delete button — the Figma "Typical services" item.
private struct ServiceRowEditor: View {
    @Binding var service: BusinessService.Service
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            labeled("Service") {
                input("Service name", text: $service.name)
            }
            HStack(spacing: 16) {
                labeled("Price min $") {
                    priceField("$", value: $service.priceMin)
                }
                labeled("Price max $") {
                    priceField("$", value: $service.priceMax)
                }
            }
            // Per-hour toggle and Delete share a row, vertically centered (Figma
            // 1096:5699): the checkbox on the left, Delete pinned to the right.
            HStack(alignment: .center, spacing: 12) {
                perHourCheckbox
                Button(action: onRemove) {
                    Text("Delete")
                        .font(.h4).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 32)
                        .secondaryButtonBackground()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.h4).foregroundStyle(.white)
            content()
        }
    }

    /// Whether this service is priced per hour — stored in `unit` ("hour" vs empty).
    /// On the consumer page this becomes the "/h" suffix; unchecked shows no unit.
    private var isPerHour: Bool {
        service.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hour"
    }

    private var perHourCheckbox: some View {
        Button(action: { service.unit = isPerHour ? "" : "hour" }) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isPerHour ? AppColors.ctaPrimary : Color.clear)
                    .frame(width: 24, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isPerHour ? Color.clear : Color.white.opacity(0.3), lineWidth: 1.5)
                    )
                    .overlay {
                        if isPerHour {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text("Per hour").font(.bodyLight).foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func input(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)))
            .font(.bodyLight).foregroundStyle(.white)
            .tint(AppColors.accentStart)
            .padding(.horizontal, 20).frame(height: 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inputFieldSurface()
    }

    private func priceField(_ placeholder: String, value: Binding<Double?>) -> some View {
        TextField("", text: Binding(
            get: { value.wrappedValue.map { String(Int($0)) } ?? "" },
            set: { value.wrappedValue = $0.isEmpty ? nil : Double($0.filter(\.isNumber)) }
        ), prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)))
        .font(.bodyLight)
        .foregroundStyle(.white)
        .tint(AppColors.accentStart)
        .keyboardType(.numberPad)
        .padding(.horizontal, 20).frame(height: 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgOverlay, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
