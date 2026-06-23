import SwiftUI
import Supabase

/// Consent / review step before a request is sent to a contractor. Tells the
/// user exactly what will happen, shows the contact email contractors will
/// reply to (prefilled from sign-in, editable), and captures explicit consent.
///
/// Note: actually sending the email is a server-side job — `sendRequest()` is a
/// local stub that shows the sent state. Wire it to your backend later.
struct QuoteRequestScreen: View {
    var contractor: Contractor? = nil
    var requestSummary: String = ""

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService

    @State private var email: String = ""
    @State private var editableRequest: String = ""
    @State private var editingEmail = false
    @State private var editingRequest = false
    @State private var sent = false
    @FocusState private var emailFocused: Bool
    @FocusState private var requestFocused: Bool

    private var isRelay: Bool { email.localizedCaseInsensitiveContains("privaterelay.appleid.com") }
    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.contains("@") && e.contains(".") && !e.hasSuffix("@") && !isRelay
    }

    var body: some View {
        ZStack {
            AppColors.bg.ignoresSafeArea()
            if sent { sentState } else { reviewState }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear {
            if email.isEmpty { email = auth.user?.email ?? "" }
            if editableRequest.isEmpty { editableRequest = requestSummary }
        }
    }

    // MARK: - Review / consent

    private var reviewState: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Back
            Button(action: { dismiss() }) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .padding(.leading, 16)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send your request?")
                            .font(.h2)
                            .foregroundStyle(.white)
                        Text("We'll email your request\(contractor != nil ? " to \(contractor!.name)" : " to this contractor"). They'll reply to you directly.")
                            .font(.bodyLight)
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    // What we send
                    if !editableRequest.isEmpty || !requestSummary.isEmpty {
                        labeledCard(title: "Your request") {
                            if editingRequest {
                                TextField("Describe your request…", text: $editableRequest, axis: .vertical)
                                    .font(.h3)
                                    .foregroundStyle(.white)
                                    .tint(AppColors.accentStart)
                                    .focused($requestFocused)
                                    .submitLabel(.done)
                                    .lineLimit(1...6)
                                    .onSubmit { editingRequest = false }
                            } else {
                                HStack(alignment: .top) {
                                    Text(editableRequest.isEmpty ? requestSummary : editableRequest)
                                        .font(.h3)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Button("Edit") {
                                        editingRequest = true
                                        requestFocused = true
                                    }
                                    .font(.bodySmall)
                                    .foregroundStyle(AppColors.accentStart)
                                    .buttonStyle(.textAction)
                                }
                            }
                        }
                    }

                    // Contact email — prefilled, editable
                    labeledCard(title: "Contractors will reply to you at") {
                        if editingEmail {
                            TextField("you@email.com", text: $email)
                                .font(.h3)
                                .foregroundStyle(.white)
                                .tint(AppColors.accentStart)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($emailFocused)
                                .submitLabel(.done)
                                .onSubmit { editingEmail = false }
                        } else {
                            HStack {
                                Text(email.isEmpty ? "Add an email" : email)
                                    .font(.h3)
                                    .foregroundStyle(email.isEmpty ? .white.opacity(0.4) : .white)
                                Spacer()
                                Button("Edit") {
                                    editingEmail = true
                                    emailFocused = true
                                }
                                .font(.bodySmall)
                                .foregroundStyle(AppColors.accentStart)
                                .buttonStyle(.textAction)
                            }
                        }

                        if isRelay {
                            warning("Apple's private relay address can't receive replies from contractors. Add a direct email.")
                        } else if !email.isEmpty && !emailValid {
                            warning("That doesn't look like a valid email.")
                        }
                    }

                    Text("By sending, you agree to share your request and contact email with this contractor so they can get back to you.")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            // Send
            Button(action: sendRequest) {
                Text("Send request")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .buttonStyle(.gradient)
            .disabled(!emailValid)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Sent confirmation

    private var sentState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(AppColors.accentStart)
            Text("Request sent")
                .font(.h2)
                .foregroundStyle(.white)
            Text("\(contractor?.name ?? "The contractor") will reply to you at \(email).")
                .font(.bodyLight)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .buttonStyle(.gradient)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Pieces

    private func labeledCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppColors.searchBg)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppColors.border, lineWidth: 1))
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.bodySmall)
            .foregroundStyle(Color(hex: "#E5A000"))
            .padding(.top, 4)
    }

    /// Stub: real sending is server-side. For now, transition to the sent state.
    private func sendRequest() {
        emailFocused = false
        requestFocused = false
        editingEmail = false
        editingRequest = false
        // TODO: POST { contractorId, requestSummary, replyToEmail } to backend,
        //       which emails the contractor from your domain with Reply-To = email.
        withAnimation(.easeInOut(duration: 0.25)) { sent = true }
    }
}
