import SwiftUI
import Combine
import AuthenticationServices
import CommonCrypto
import Supabase
import GoogleSignIn

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var isRestoringSession = true
    @Published var message: String?
    @Published var isLoading = false

    var isSignedIn: Bool { user != nil }

    init() {
        Task { await restoreSession() }
        Task { await listenForAuthChanges() }
    }

    // MARK: - Session

    private func listenForAuthChanges() async {
        for await (event, session) in supabase.auth.authStateChanges {
            if event == .signedIn || event == .tokenRefreshed {
                user = session?.user
            } else if event == .signedOut {
                user = nil
            }
        }
    }

    private func restoreSession() async {
        defer { isRestoringSession = false }
        do {
            let session = try await supabase.auth.session
            user = session.user
        } catch {
            user = nil
        }
    }

    // MARK: - Email OTP

    func sendOTP(email: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.contains(".") else {
            message = "Enter a valid email address."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await supabase.auth.signInWithOTP(
                email: trimmed,
                redirectTo: URL(string: "brightglow://login"),
                shouldCreateUser: true
            )
        } catch {
            message = "Couldn't send code: \(error.localizedDescription)"
        }
    }

    func verifyOTP(email: String, code: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let session = try await supabase.auth.verifyOTP(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                token: code.trimmingCharacters(in: .whitespacesAndNewlines),
                type: .email
            )
            user = session.user
        } catch {
            message = "Invalid or expired code. Try again."
        }
    }

    // MARK: - Sign in with Apple

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    func handleApple(_ result: Result<ASAuthorization, Error>) {
        if case .failure(let error) = result {
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                message = "Apple sign-in failed: \(error.localizedDescription)"
            }
            return
        }
        guard case .success(let auth) = result,
              let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else { return }

        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: token)
                )
                user = session.user
            } catch {
                message = "Apple sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Google OAuth

    func signInWithGoogle() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: "927196636577-3ic9ibm0nijop3ifd4lc61tkf196grii.apps.googleusercontent.com"
        )

        // Clear any cached session so the nonce state is always fresh
        GIDSignIn.sharedInstance.signOut()

        let rawNonce = randomNonce()
        let hashedNonce = sha256(rawNonce)

        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: rootVC,
                    hint: nil,
                    additionalScopes: nil,
                    nonce: hashedNonce
                )
                guard let idToken = result.user.idToken?.tokenString else {
                    message = "Google sign-in failed: missing token."
                    return
                }
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .google, idToken: idToken, nonce: rawNonce)
                )
                user = session.user
            } catch {
                if (error as NSError).code != GIDSignInError.canceled.rawValue {
                    message = "Google sign-in failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(input.utf8)
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }


    // MARK: - Sign out

    func signOut() {
        Task {
            try? await supabase.auth.signOut()
            user = nil
        }
    }
}
