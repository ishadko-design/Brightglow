import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// Three canonical button styles for Brightglow.
//
// Usage:
//   Button { ... } label: {
//       Text("Label").font(.h3).foregroundStyle(.white)
//           .frame(maxWidth: .infinity).frame(height: 54)
//   }
//   .buttonStyle(.gradient)          // primary action
//   .buttonStyle(.frosted)           // secondary action
//   .buttonStyle(.textAction)        // tertiary / text-only
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

// MARK: - Frosted (secondary)

struct FrostedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                ZStack {
                    Color.clear.background(.ultraThinMaterial)
                    Color.white.opacity(0.2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 32))
            .overlay(RoundedRectangle(cornerRadius: 32).stroke(Color.white.opacity(0.2), lineWidth: 1))
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

extension ButtonStyle where Self == FrostedButtonStyle {
    static var frosted: FrostedButtonStyle { FrostedButtonStyle() }
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
