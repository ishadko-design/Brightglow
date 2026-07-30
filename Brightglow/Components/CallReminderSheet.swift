import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CallReminderSheet
// Bottom sheet shown before dialing a business, from anywhere a "Call" action
// lives (the gallery footer and each list row). A "Help us grow" nudge to name-
// drop Brightglow when the business picks up, with a single primary Call action.
// The actual call is never
// placed here — Call hands off to the system dialer, which shows its own
// confirmation with the number pre-filled.
//
// Presented as a custom bottom overlay (dim backdrop + edge-to-edge card) rather
// than a system `.sheet`: on iOS 26 a detented system sheet renders as an inset
// floating card, and the design calls for a flush, full-width bottom sheet that
// matches the app's shared `BottomSheet`. This owns its own backdrop, grabber,
// and drag-to-dismiss so both entry points present the identical pop-up.
// ─────────────────────────────────────────────────────────────────────────────

struct CallReminderSheet: View {
    let contractor: Contractor
    /// Fired by the Call button — the caller dismisses this sheet and dials.
    let onCall: () -> Void
    /// Fired by the backdrop tap or a drag-down — the caller hides the sheet.
    let onDismiss: () -> Void

    /// Tracks a downward drag so the card follows the finger and dismisses past
    /// a threshold, the same feel as the shared `BottomSheet`.
    @GestureState private var dragY: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dim backdrop — tap anywhere outside the card to dismiss.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture { onDismiss() }

            card
                .offset(y: max(0, dragY))
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($dragY) { value, state, _ in
                            state = value.translation.height
                        }
                        .onEnded { value in
                            if value.predictedEndTranslation.height > 250
                                || value.translation.height > 120 {
                                onDismiss()
                            }
                        }
                )
                .transition(.move(edge: .bottom))
        }
        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: dragY)
    }

    // Full-width card: rounded top corners, flush to the bottom and both sides.
    private var card: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 44, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 4)

            Text("Help us grow")
                .font(.h2)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            Image("fig_call_reminder")
                .resizable()
                .scaledToFit()
                .frame(height: 210)
                .padding(.top, 16)

            Text("Thank you for choosing Brightglow! When they pick up, mention you found them on Brightglow.")
                .font(.bodyLight)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Spacer(minLength: 24)

            Button(action: onCall) {
                Text("Call")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 40)
                    .background(AppColors.btnPrimary,
                                in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .frame(height: 470, alignment: .top)
        .background(
            AppColors.bg
                .clipShape(.rect(topLeadingRadius: 32, topTrailingRadius: 32))
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
