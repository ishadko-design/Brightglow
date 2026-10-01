import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PriceBreakdownSheet  (PROTOTYPE, 2026-09-30)
// "How we estimate" — opened from the ⓘ next to the results header price.
// Shows the AI estimate's itemized parts (permit, circuit, trench, assembly…)
// so the number reads as the sum of real work, not a guess. Formula estimates
// carry no parts; the sheet then shows the plain explainer text it replaced
// (the old system alert).
//
// Built from CallReminderSheet's skeleton and the app's existing tokens only —
// same backdrop, grabber, flush card, h2 title, bodyLight/bodySmall text,
// white-opacity tiers and the primary pill button. No new colors or fonts.
// ─────────────────────────────────────────────────────────────────────────────

struct PriceBreakdownSheet: View {
    let tier: PriceTier
    /// The plain explainer (used when the estimate has no itemized parts).
    let fallbackText: String
    let onDismiss: () -> Void

    @GestureState private var dragY: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture { onDismiss() }

            card
                .offset(y: max(0, dragY))
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($dragY) { value, state, _ in state = value.translation.height }
                        .onEnded { value in
                            if value.predictedEndTranslation.height > 250 || value.translation.height > 120 {
                                onDismiss()
                            }
                        }
                )
                .transition(.move(edge: .bottom))
        }
        .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: dragY)
    }

    private var parts: [PriceComponent] { tier.components ?? [] }

    private var card: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 44, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 4)

            Text("How we estimate")
                .font(.h2)
                .foregroundStyle(.white)
                .padding(.top, 12)

            if parts.isEmpty {
                Text(fallbackText)
                    .font(.bodyLight)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            } else {
                Text(totalLine)
                    .font(.bodyLight)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            row(part)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 320)
                .padding(.top, 20)

                Text(footnote)
                    .font(.bodySmall)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }

            Button(action: onDismiss) {
                Text("Got it")
                    .font(.h3)
                    .foregroundStyle(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 40)
                    .background(AppColors.btnPrimary,
                                in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(
            AppColors.bg
                .clipShape(.rect(topLeadingRadius: 32, topTrailingRadius: 32))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// One part: its name (with "if needed" for uncertain parts) and its range.
    private func row(_ part: PriceComponent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(part.name)
                    .font(.bodySmall)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !part.certain {
                    Text("If needed")
                        .font(.bodySmall)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            Text("\(dollars(part.low))–\(dollars(part.high))")
                .font(.bodySmall)
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
        }
    }

    private var totalLine: String {
        let typical = tier.typical.map { "Typically ~\(dollars(Double($0))). " } ?? ""
        return "\(typical)Most jobs land between \(dollars(Double(tier.min)))–\(dollars(Double(tier.max)))."
    }

    private var footnote: String {
        let src = tier.searched == true ? "current local prices" : "typical local costs"
        return "Each part priced from \(src). Parts marked “If needed” count toward the high end. "
            + "The business gives you the final quote."
    }

    private func dollars(_ v: Double) -> String {
        if v >= 1000 {
            let k = v / 1000
            return k >= 10 ? "$\(Int(k.rounded()))k" : "$\(String(format: "%.1f", k).replacingOccurrences(of: ".0", with: ""))k"
        }
        return "$\(Int((v / 10).rounded() * 10))"
    }
}
