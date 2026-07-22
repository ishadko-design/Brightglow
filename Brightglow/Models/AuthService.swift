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

    // MARK: - Profile

    // The consumer profile (Figma 1150:3839) edits three things. Email is the
    // identity itself — OTP-verified possession — so it's shown but not editable
    // here; the name parts and the avatar path live in the auth user's metadata,
    // which avoids a `profiles` table for what is only ever read back by its owner.

    var firstName: String { metadataString("first_name") ?? "" }
    var lastName: String { metadataString("last_name") ?? "" }
    /// Object path in the `avatars` bucket, e.g. `<uid>/<uuid>.jpg`.
    var avatarPath: String? { metadataString("avatar_path") }

    /// Share of the profile the user has filled in, as the whole percent the
    /// header subtitle shows ("71 % complete" in the mock). Email always counts
    /// — you can't be signed in without it — so the floor is 25%.
    var profileCompletion: Int {
        let filled = [
            !(user?.email ?? "").isEmpty,
            !firstName.isEmpty,
            !lastName.isEmpty,
            avatarPath != nil,
        ].filter { $0 }.count
        return Int((Double(filled) / 4.0 * 100).rounded())
    }

    private func metadataString(_ key: String) -> String? {
        guard let value = user?.userMetadata[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// Persist the editable profile fields onto the auth user. Only the keys
    /// passed are touched, so saving a name can't clear the avatar.
    @discardableResult
    func updateProfile(firstName: String? = nil,
                       lastName: String? = nil,
                       avatarPath: String? = nil) async -> Bool {
        var data: [String: AnyJSON] = [:]
        if let firstName { data["first_name"] = .string(firstName) }
        if let lastName { data["last_name"] = .string(lastName) }
        if let avatarPath { data["avatar_path"] = .string(avatarPath) }
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

    // MARK: - Avatar

    private static let avatarBucket = "avatars"

    /// Upload avatar bytes to `<uid>/<uuid>.<ext>` and record the path on the
    /// user. Storage RLS gates writes on that first path segment, so the folder
    /// name isn't cosmetic — it's the authorization key.
    func uploadAvatar(_ data: Data) async -> Bool {
        guard let uid = user?.id.uuidString.lowercased() else { return false }
        let contentType = BusinessService.imageContentType(for: data)
        let path = "\(uid)/\(UUID().uuidString).\(BusinessService.fileExtension(for: contentType))"
        do {
            try await supabase.storage.from(Self.avatarBucket).upload(
                path,
                data: data,
                options: FileOptions(cacheControl: "31536000", contentType: contentType, upsert: false)
            )
        } catch {
            #if DEBUG
            print("👤 avatar upload failed — \(error)")
            #endif
            return false
        }
        return await updateProfile(avatarPath: path)
    }

    static func avatarURL(_ path: String) -> URL? {
        try? supabase.storage.from(avatarBucket).getPublicURL(path: path)
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
