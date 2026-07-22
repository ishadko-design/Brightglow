import SwiftUI
import PhotosUI
import Supabase

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
        .task { await load() }
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
                                .font(.bodySmall).foregroundStyle(.white.opacity(0.5))
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

                    // Pictures
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pictures").font(.h4).foregroundStyle(.white)
                            Text("Show your best relevant work.")
                                .font(.bodySmall).foregroundStyle(.white.opacity(0.6))
                        }
                        photoStrip
                        if let uploadMsg {
                            Text(uploadMsg).font(.bodySmall).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
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
    }

    /// Horizontal strip of work photos, each removable, ending in an add tile.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(working.photos.enumerated()), id: \.element) { index, path in
                    photoCell(index: index, path: path)
                }
                addPhotoTile
            }
            .padding(.vertical, 2)
        }
    }

    private func photoCell(index: Int, path: String) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppColors.fillSubtle)
                .overlay {
                    if let url = BusinessService.publicURL(path) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                            } else {
                                Color.clear
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button(action: { removePhoto(index) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(6)
        }
        .frame(width: 112, height: 136)
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

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, let placeId else { return }
        uploading = true; uploadMsg = nil
        var added = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                let path = try await BusinessService.uploadImage(
                    data, contentType: contentType(for: data), placeId: placeId)
                working.photos.append(path)
                added += 1
            } catch {
                #if DEBUG
                print("🏢 photo upload failed — \(error)")
                #endif
            }
        }
        uploading = false
        photoItems = []
        uploadMsg = added > 0 ? "Added \(added) photo\(added == 1 ? "" : "s"). Remember to Save." : "Upload failed."
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

    private func removePhoto(_ index: Int) {
        guard working.photos.indices.contains(index) else { return }
        working.photos.remove(at: index)
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
            Button(action: onRemove) {
                Text("Delete")
                    .font(.h4).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 32)
                    .secondaryButtonBackground()
            }
            .buttonStyle(.plain)
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.h4).foregroundStyle(.white)
            content()
        }
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
