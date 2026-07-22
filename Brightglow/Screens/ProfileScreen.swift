import SwiftUI
import PhotosUI
import Supabase

/// The consumer's profile (Figma 1150:3839) — deliberately the same page as the
/// business Settings screen with different fields: same pushed slide-in, same
/// back-arrow header, same card, same `AccountFooter`. It used to be a bottom
/// sheet showing a read-only identity block; the design collapsed the two into
/// one shape, so this is now a real editor.
///
/// Name and last name save on a pause the way the business editor does — there
/// is no Save button in either mock. Email is shown but not editable: possession
/// of it is the identity (OTP-verified), so changing it is an auth flow, not a
/// text field.
struct ProfileScreen: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var loaded = false

    @State private var avatarItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var errorMessage: String?
    @State private var autosaveTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                form
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableSwipeBack()
        .preferredColorScheme(.dark)
        .onAppear {
            guard !loaded else { return }
            firstName = auth.firstName
            lastName = auth.lastName
            loaded = true
        }
        .onChange(of: firstName) { _, _ in scheduleAutosave() }
        .onChange(of: lastName) { _, _ in scheduleAutosave() }
        .onDisappear { flushPendingSave() }
        .onChange(of: avatarItem) { _, item in Task { await uploadAvatar(item) } }
    }

    // MARK: - Header

    /// Back arrow, title, and the completion read-out the mock puts under it.
    /// No buttons beyond the arrow — the only account actions live in the footer.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Profile")
                    .font(.h2).foregroundStyle(.white)
                Text("\(auth.profileCompletion) % complete")
                    .font(.bodySmall).foregroundStyle(AppColors.textSecondary)
            }
            .padding(.top, 4)
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
                AccountFooter()
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private var profileSection: some View {
        card {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    avatarPreview
                    VStack(alignment: .leading, spacing: 12) {
                        PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
                            Text("Upload logo")
                                .font(.h4).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 32)
                                .secondaryButtonBackground()
                        }
                        .disabled(uploading)
                        Text("Square works best. PNG or JPG.")
                            .font(.bodySmall).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                }

                field("Name") {
                    fieldInput("First name", text: $firstName)
                }
                field("Last name") {
                    fieldInput("Last name", text: $lastName)
                }
                field("Email") {
                    // Read-only: the address is the account, not a preference.
                    Text(auth.user?.email ?? "")
                        .font(.bodyLight).foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        .inputFieldSurface()
                }
            }
        }
    }

    private var avatarPreview: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(AppColors.fillSubtle)
            .frame(width: 104, height: 104)
            .overlay {
                if uploading {
                    ProgressView().tint(.white)
                } else if let path = auth.avatarPath, let url = AuthService.avatarURL(path) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            avatarPlaceholder
                        }
                    }
                } else {
                    avatarPlaceholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var avatarPlaceholder: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 32)).foregroundStyle(.white.opacity(0.4))
    }

    // MARK: - Autosave

    /// Same contract as the business editor: no Save button, so a change schedules
    /// a write and resets the timer, and only the pause at the end hits the network.
    private func scheduleAutosave() {
        guard loaded, dirty else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private var dirty: Bool {
        loaded && (firstName != auth.firstName || lastName != auth.lastName)
    }

    /// Leaving inside the debounce window must not lose the edit. Deliberately
    /// does not touch `@State` — the view is going away.
    private func flushPendingSave() {
        guard loaded, dirty else { return }
        autosaveTask?.cancel()
        let auth = self.auth
        let first = firstName, last = lastName
        Task { await auth.updateProfile(firstName: first, lastName: last) }
    }

    private func save() async {
        let ok = await auth.updateProfile(firstName: firstName, lastName: lastName)
        // A successful autosave says nothing; a failed one has to, since there's
        // no Save button left to retry from.
        errorMessage = ok ? nil : "Couldn't save your changes."
    }

    private func uploadAvatar(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploading = true
        defer { uploading = false; avatarItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Couldn't read that image."
            return
        }
        errorMessage = await auth.uploadAvatar(data) ? nil : "Picture upload failed."
    }

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
        }
        .padding(16)
        .background(AppColors.cardSurface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: - Small view helpers

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardSurface,
                        in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(.horizontal, 16)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.h4).foregroundStyle(.white)
            content()
        }
    }

    private func fieldInput(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text,
                  prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)))
            .font(.bodyLight).foregroundStyle(.white)
            .tint(AppColors.accentStart)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .inputFieldSurface()
    }
}

/// Matches the business editor's field treatment so the two profiles read as the
/// same page (same `bgOverlay` fill, 1.5pt border, 32pt radius).
private extension View {
    func inputFieldSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        return self
            .background(AppColors.bgOverlay, in: shape)
            .overlay(shape.stroke(AppColors.searchBorder, lineWidth: 1.5))
    }
}
