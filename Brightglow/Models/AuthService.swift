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

    // MARK: - Magic-link callback

    /// Completes a sign-in from a `brightglow://login` callback — the link tapped
    /// in the email. Supabase can hand the credentials back two different ways
    /// depending on how the project's flow is configured:
    ///
    ///   • PKCE:     `brightglow://login?code=…`         → exchange the code
    ///   • Implicit: `brightglow://login#access_token=…` → set the tokens directly
    ///
    /// We handle both so the link works regardless, and — unlike the old
    /// `try?` — we surface failures instead of swallowing them, so an expired or
    /// already-used link explains itself rather than silently leaving the user on
    /// the login screen.
    func handleOpenURL(_ url: URL) async {
        let fragment = fragmentParameters(url)

        // Supabase reports rejected/expired links via an `error_description`.
        if let error = fragment["error_description"] ?? fragment["error"] {
            message = error.replacingOccurrences(of: "+", with: " ")
            return
        }

        do {
            if let accessToken = fragment["access_token"],
               let refreshToken = fragment["refresh_token"] {
                let session = try await supabase.auth.setSession(
                    accessToken: accessToken, refreshToken: refreshToken)
                user = session.user
            } else {
                // PKCE (`?code=…`) — the SDK exchanges it using the verifier it
                // stashed when the link was requested.
                let session = try await supabase.auth.session(from: url)
                user = session.user
            }
        } catch {
            #if DEBUG
            print("🔗 sign-in link failed for \(url.absoluteString) — \(error)")
            #endif
            message = "That sign-in link didn't work. It may have expired — request a new one."
        }
    }

    /// Parse a URL fragment (`#a=b&c=d`) into a dictionary. The implicit flow
    /// returns the session tokens here rather than in the query string, so
    /// `URLComponents.queryItems` never sees them.
    private func fragmentParameters(_ url: URL) -> [String: String] {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            return [:]
        }
        var result: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            result[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return result
    }

    // MARK: - Sign in with Apple

    // Raw nonce generated for the in-flight Apple request; Apple hashes the one
    // we put on the request, and Supabase needs the *raw* value to verify the
    // returned identity token. Held between configure and completion.
    private var appleRawNonce: String?

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let rawNonce = randomNonce()
        appleRawNonce = rawNonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(rawNonce)
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
                    credentials: .init(provider: .apple, idToken: token, nonce: appleRawNonce)
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

    // MARK: - Profile

    // We deliberately collect the minimum: a first name and the email. Email is
    // the identity itself — OTP-verified possession — so it's shown but not
    // editable here; the first name lives in the auth user's metadata, which
    // avoids a `profiles` table for what is only ever read back by its owner.

    var firstName: String { metadataString("first_name") ?? "" }

    private func metadataString(_ key: String) -> String? {
        guard let value = user?.userMetadata[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// Persist the editable profile fields onto the auth user. Only the keys
    /// passed are touched.
    @discardableResult
    func updateProfile(firstName: String? = nil) async -> Bool {
        var data: [String: AnyJSON] = [:]
        if let firstName { data["first_name"] = .string(firstName) }
        guard !data.isEmpty else { return true }
        do {
            user = try await supabase.auth.update(user: UserAttributes(data: data))
            return true
        } catch {
            #if DEBUG
            print("👤 profile save failed — \(error)")
            #endif
            return false
        }
    }

    // MARK: - Delete account

    /// Permanently deletes the signed-in user's account and all their data.
    /// Calls the `delete-account` Edge Function, which purges their leads,
    /// messages, and photos, then deletes the auth user. The SDK attaches the
    /// current session's access token automatically (fetchWithAuth), which the
    /// function requires. Required by App Store Guideline 5.1.1(v).
    func deleteAccount() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await supabase.functions.invoke("delete-account")
            // The server-side user is gone; clear the local session so the app
            // returns to the signed-out state.
            try? await supabase.auth.signOut()
            user = nil
        } catch {
            message = "Couldn't delete your account. Please try again."
        }
    }
}
