import SwiftUI

/// The account actions that close out both profile screens — the consumer's
/// (Figma 1150:3839) and the business's Settings (Figma 1096:5699). Both mocks
/// end the same way: a hairline rule, then `Sign out` and `Delete account` side
/// by side as content-hugging frosted pills, centered.
///
/// It lives here rather than in either screen because "same view" is the point —
/// the two profiles are meant to be the same page with different fields, and
/// these are the only account-level buttons on either of them.
struct AccountFooter: View {
    @EnvironmentObject private var auth: AuthService
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppColors.fillSubtle)
                .padding(.horizontal, 4)

            HStack(spacing: 12) {
                Button(action: { auth.signOut() }) {
                    Text("Sign out")
                        .font(.h3).foregroundStyle(.white)
                        .padding(.horizontal, 32).frame(height: 48)
                }
                .buttonStyle(.secondary)

                Button(action: { confirmDelete = true }) {
                    Text("Delete account")
                        .font(.h3).foregroundStyle(.white)
                        .padding(.horizontal, 32).frame(height: 48)
                }
                .buttonStyle(.secondary)
                .disabled(auth.isLoading)
            }
            .padding(.top, 32)
        }
        // Deleting the account is irreversible and takes the user's requests,
        // messages and photos with it — App Store Guideline 5.1.1(v) requires the
        // in-app path, but never an unconfirmed one.
        .confirmationDialog(
            "Delete your account?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await auth.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and all your requests, messages, and photos. This can't be undone.")
        }
    }
}
