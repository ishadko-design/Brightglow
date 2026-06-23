import SwiftUI

struct OTPVerifyView: View {
    @EnvironmentObject var auth: AuthService
    let email: String
    var onBack: () -> Void

    @State private var code = ""
    @State private var secondsLeft = 60
    @State private var timer: Timer?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Back button
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 60)

                Spacer()

                VStack(spacing: 8) {
                    Text("Check your email")
                        .font(.h2)
                        .foregroundStyle(.white)

                    Text("We sent a 6-digit code to")
                        .font(.bodyLight)
                        .foregroundStyle(.white.opacity(0.5))

                    Text(email)
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer().frame(height: 48)

                // OTP input
                TextField("", text: $code, prompt: Text("000000").foregroundStyle(.white.opacity(0.2)))
                    .font(.h2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .onChange(of: code) { _, newValue in
                        code = String(newValue.filter(\.isNumber).prefix(6))
                        if code.count == 6 { verify() }
                    }
                    .frame(height: 64)
                    .background {
                        ZStack {
                            Color.clear.background(.ultraThinMaterial)
                            AppColors.searchBg
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppColors.searchBorder, lineWidth: 1.5))
                    .padding(.horizontal, 48)

                Spacer().frame(height: 24)

                // Verify button
                Button(action: verify) {
                    Group {
                        if auth.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Verify")
                                .font(.h3)
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                }
                .buttonStyle(.gradient)
                .disabled(code.count < 6 || auth.isLoading)
                .padding(.horizontal, 24)

                Spacer().frame(height: 24)

                // Resend
                Button(action: resend) {
                    if secondsLeft > 0 {
                        Text("Resend code in \(secondsLeft)s")
                            .font(.bodySmall)
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        Text("Resend code")
                            .font(.bodySmall)
                            .foregroundStyle(AppColors.accentStart)
                    }
                }
                .buttonStyle(.textAction)
                .disabled(secondsLeft > 0)

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            focused = true
            startTimer()
        }
        .onDisappear { timer?.invalidate() }
        .alert("Sign in", isPresented: Binding(
            get: { auth.message != nil },
            set: { if !$0 { auth.message = nil } }
        )) {
            Button("OK", role: .cancel) { auth.message = nil }
        } message: {
            Text(auth.message ?? "")
        }
    }

    private func verify() {
        guard code.count == 6 else { return }
        Task { await auth.verifyOTP(email: email, code: code) }
    }

    private func resend() {
        code = ""
        secondsLeft = 60
        startTimer()
        Task { await auth.sendOTP(email: email) }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                if secondsLeft > 0 { secondsLeft -= 1 }
                else { timer?.invalidate() }
            }
        }
    }
}
