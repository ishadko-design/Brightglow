import SwiftUI
import Supabase

struct ProfileScreen: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with close
                HStack {
                    Text("Profile")
                        .font(.h2)
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
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
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }
}
