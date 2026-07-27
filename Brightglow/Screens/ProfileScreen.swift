import SwiftUI
import Supabase

/// The consumer's profile (Figma 1150:3839) — deliberately the same page as the
/// business Settings screen with different fields: same pushed slide-in, same
/// back-arrow header, same card, same `AccountFooter`. It used to be a bottom
/// sheet showing a read-only identity block; the design collapsed the two into
/// one shape, so this is now a real editor.
///
/// By design we ask for as little as possible: only a first name and the email.
/// The name saves on a pause the way the business editor does — there is no Save
/// button in either mock. Email is shown but not editable: possession of it is
/// the identity (OTP-verified), so changing it is an auth flow, not a text field.
struct ProfileScreen: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var loaded = false

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
            loaded = true
        }
        .onChange(of: firstName) { _, _ in scheduleAutosave() }
        .onDisappear { flushPendingSave() }
    }

    // MARK: - Header

    /// Back arrow and title. No buttons beyond the arrow — the only account
    /// actions live in the footer.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: { dismiss() }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            Text("Profile")
                .font(.h2).foregroundStyle(.white)
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
                field("Name") {
                    fieldInput("First name", text: $firstName)
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
        loaded && firstName != auth.firstName
    }

    /// Leaving inside the debounce window must not lose the edit. Deliberately
    /// does not touch `@State` — the view is going away.
    private func flushPendingSave() {
        guard loaded, dirty else { return }
        autosaveTask?.cancel()
        let auth = self.auth
        let first = firstName
        Task { await auth.updateProfile(firstName: first) }
    }

    private func save() async {
        let ok = await auth.updateProfile(firstName: firstName)
        // A successful autosave says nothing; a failed one has to, since there's
        // no Save button left to retry from.
        errorMessage = ok ? nil : "Couldn't save your changes."
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
