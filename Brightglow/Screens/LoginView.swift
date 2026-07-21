import SwiftUI
import AuthenticationServices
import AVKit

struct LoginView: View {
    @EnvironmentObject var auth: AuthService
    @State private var email = ""
    @State private var emailSent = false
    @FocusState private var emailFocused: Bool

    var body: some View {
        ZStack {
            loginScreen
        }
        .alert("Sign in", isPresented: Binding(
            get: { auth.message != nil },
            set: { if !$0 { auth.message = nil } }
        )) {
            Button("OK", role: .cancel) { auth.message = nil }
        } message: {
            Text(auth.message ?? "")
        }
    }

    // MARK: - Main screen

    private var loginScreen: some View {
        ZStack {
            // Layer 1: looping video
            LoopingVideoPlayer(videoName: "Handyman", videoExtension: "mp4")
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Layer 2: the designed protection layer over the video — the warm
            // gradient scrim that keeps the wordmark and form legible.
            //
            // Composited at full strength: the asset carries its own alpha
            // (transparent where the video should show through), so it must NOT
            // be dimmed here. If the video ever disappears behind this layer,
            // the overlay has been re-exported flattened — check that its PNG
            // still has a real alpha channel rather than adding .opacity().
            Image("VideoOverlay")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Layer 3: wordmark, centered in the vertical middle (matches the
            // splash and the email-sent screen — the logo is centered everywhere).
            Text("Brightglow")
                .font(.h1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)

            // Layer 4: form pinned to bottom
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 16) {
                    if emailSent {
                        VStack(spacing: 12) {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(0.8))
                            Text("Check your email")
                                .font(.h2)
                                .foregroundStyle(.white)
                            Text("We sent a sign-in link to\n**\(email)**\n\nTap the link to open the app.")
                                .font(.bodySmall)
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                            Button("Use a different email") {
                                emailSent = false
                                email = ""
                            }
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.4))
                            .buttonStyle(.textAction)
                            .padding(.top, 8)
                        }
                        .padding(.vertical, 16)
                    } else {
                        emailField
                        appleButton
                        googleButton

                        Text("By continuing you agree to our **Terms & Privacy Policy**")
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .preferredColorScheme(.dark)
        .onTapGesture { emailFocused = false }
    }

    // MARK: - Email field

    private var emailField: some View {
        HStack(spacing: 8) {
            TextField("", text: $email, prompt:
                Text("Email").foregroundStyle(.white.opacity(0.5))
            )
            .font(.bodyLight)
            .foregroundStyle(.white)
            .tint(.white)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($emailFocused)
            .submitLabel(.go)
            .onSubmit { sendCode() }

            Button(action: sendCode) {
                ZStack {
                    if auth.isLoading {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.forward")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(
                        colors: [AppColors.accentStart, AppColors.accentEnd],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(Circle())
            }
            .disabled(auth.isLoading)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(height: 64)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 32).fill(Color.black.opacity(0.85))
                RoundedRectangle(cornerRadius: 32)
                    .fill(LinearGradient(
                        colors: [.black, Color.white.opacity(0.4)],
                        startPoint: .leading, endPoint: .trailing
                    ).opacity(0.5))
                RoundedRectangle(cornerRadius: 32).fill(.ultraThinMaterial.opacity(0.2))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 32).stroke(Color.white.opacity(0.2), lineWidth: 3))
    }

    // MARK: - Social buttons

    private var appleButton: some View {
        ZStack {
            SignInWithAppleButton(.continue,
                onRequest: auth.configureAppleRequest,
                onCompletion: auth.handleApple)
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 32))
                .opacity(0.011)

            frostedButton(icon: {
                Image(systemName: "apple.logo")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }, label: "Continue with Apple")
            .allowsHitTesting(false)
        }
        .frame(height: 56)
    }

    private var googleButton: some View {
        Button(action: auth.signInWithGoogle) {
            frostedButton(icon: {
                Image("GoogleIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
            }, label: "Continue with Google")
        }
        .buttonStyle(.textAction)
        .frame(height: 56)
    }

    @ViewBuilder
    private func frostedButton<I: View>(icon: () -> I, label: String) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(label)
                .font(.h3)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background {
            ZStack {
                Color.clear.background(.ultraThinMaterial)
                Color.white.opacity(0.2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay(RoundedRectangle(cornerRadius: 32).stroke(Color.white.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Action

    private func sendCode() {
        emailFocused = false
        Task {
            await auth.sendOTP(email: email)
            if auth.message == nil { emailSent = true }
        }
    }
}

// MARK: - Looping video player

private struct LoopingVideoPlayer: UIViewRepresentable {
    let videoName: String
    let videoExtension: String

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black

        guard let url = Bundle.main.url(forResource: videoName, withExtension: videoExtension) else {
            assertionFailure("\(videoName).\(videoExtension) is missing from the bundle")
            return view
        }

        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }

        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill

        player.play()
        context.coordinator.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        // Nothing to size — the player layer IS the view's layer, so UIKit keeps
        // it matched to the view's bounds automatically.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The AVPlayerLayer is the view's own backing layer, so it always tracks the
    /// view's bounds. (As a manually-framed sublayer it could stay zero-sized and
    /// render black if the frame was set before layout.)
    class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    class Coordinator {
        var player: AVPlayer?
        deinit { player?.pause() }
    }
}
