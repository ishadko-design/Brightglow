import SwiftUI
import Supabase

struct ProfileScreen: View {
    /// Tapping a past search re-runs it on the landing. Optional so previews /
    /// other callers can present the profile without wiring search.
    var onSelectSearch: ((String) -> Void)? = nil
    /// Opens the business dashboard. Shown only to owners; the host dismisses this
    /// sheet then pushes the dashboard.
    var onOpenBusiness: (() -> Void)? = nil

    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var businessStore: BusinessStore
    @State private var showDeleteConfirm = false
    @State private var history: [SearchHistoryStore.Entry] = []

    var body: some View {
        ZStack {
            AppColors.bgSurface.ignoresSafeArea()

            VStack(spacing: 0) {
                // Title — the grab handle (drag indicator) is the dismiss affordance,
                // matching the app's other bottom sheets.
                HStack {
                    Text("Profile")
                        .font(.h2)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Identity
                VStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.8))
                    if let name = auth.user?.userMetadata["full_name"]?.stringValue, !name.isEmpty {
                        Text(name)
                            .font(.h3)
                            .foregroundStyle(.white)
                    }
                    if let email = auth.user?.email, !email.isEmpty {
                        Text(email)
                            .font(.bodyLight)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if let provider = auth.user?.appMetadata["provider"]?.stringValue {
                        Text("Signed in with \(provider.capitalized)")
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.top, 40)

                // Recent searches — tap to run again. Takes the middle of the sheet
                // when there's history; otherwise a Spacer keeps the buttons pinned.
                if history.isEmpty {
                    Spacer()
                } else {
                    searchHistorySection
                }

                // For business — only for owners (an email matched to a lead).
                // Opens the lead dashboard + page editor.
                if businessStore.isOwner {
                    Button(action: { onOpenBusiness?() }) {
                        HStack(spacing: 12) {
                            Image(systemName: "briefcase.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.8))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("For business")
                                    .font(.h4).foregroundStyle(.white)
                                Text("Manage your requests and page")
                                    .font(.bodySmall).foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.horizontal, 16).frame(height: 56)
                        .background(Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                // Sign out
                Button(action: { auth.signOut() }) {
                    Text("Sign out")
                        .font(.h3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(.frosted)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                // Delete account — App Store Guideline 5.1.1(v) requires an
                // in-app way to delete the account. Confirmed before running,
                // since it's irreversible.
                Button(role: .destructive, action: { showDeleteConfirm = true }) {
                    Text("Delete account")
                        .font(.bodyLight)
                        .foregroundStyle(Color.red.opacity(0.9))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .disabled(auth.isLoading)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await auth.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and all your requests, messages, and photos. This can't be undone.")
        }
        .preferredColorScheme(.dark)
        .onAppear { history = SearchHistoryStore.all() }
        // Match the app's bottom-sheet affordance: grab handle, rounded surface.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(AppColors.bgSurface)
    }

    // MARK: - Recent searches

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent searches")
                    .font(.h4)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("Clear") {
                    SearchHistoryStore.clear()
                    withAnimation(.easeInOut(duration: 0.15)) { history = [] }
                }
                .font(.bodySmall)
                .foregroundStyle(AppColors.accentStart)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(history) { entry in
                        historyRow(entry)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 32)
    }

    private func historyRow(_ entry: SearchHistoryStore.Entry) -> some View {
        Button(action: { onSelectSearch?(entry.query) }) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.4))
                Text(entry.query)
                    .font(.bodyLight)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onSelectSearch == nil)
    }
}
