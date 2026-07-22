import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Three canonical button styles for Brightglow.
//
// Usage:
//   Button { ... } label: {
//       Text("Label").font(.h3).foregroundStyle(.white)
//           .frame(maxWidth: .infinity).frame(height: 56)
//   }
//   .buttonStyle(.gradient)          // primary action
//   .buttonStyle(.secondary)         // secondary action
//   .buttonStyle(.textAction)        // tertiary / text-only
//
// The secondary style has exactly one visual definition — `secondaryButtonBackground()`
// in SecondaryButton.swift. Use `.buttonStyle(.secondary)` when the button owns its
// whole label, or call `.secondaryButtonBackground()` directly when the background
// wraps a label inside a `.plain` button. Both render identically by construction.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Gradient (primary)

struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isEnabled
                    ? AnyShapeStyle(AppColors.accentGradient)
                    : AnyShapeStyle(Color.white.opacity(0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 32))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Secondary

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .secondaryButtonBackground()
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Text (tertiary)

struct TextActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Convenience shorthands

extension ButtonStyle where Self == GradientButtonStyle {
    static var gradient: GradientButtonStyle { GradientButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == TextActionButtonStyle {
    static var textAction: TextActionButtonStyle { TextActionButtonStyle() }
}

// MARK: - Press-scale (card / non-standard buttons)

struct PressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
