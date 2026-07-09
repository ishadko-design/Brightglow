import SwiftUI
import Supabase

struct ProfileScreen: View {
    @EnvironmentObject private var auth: AuthService
    @State private var showDeleteConfirm = false

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

                Spacer()

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
        // Match the app's bottom-sheet affordance: grab handle, rounded surface.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(AppColors.bgSurface)
    }
}
