import SwiftUI

extension View {
    /// The one definition of Brightglow's secondary button surface: a background
    /// blur under the translucent light fill, clipped to a capsule.
    ///
    /// `SecondaryButtonStyle` (`.buttonStyle(.secondary)`) is a thin wrapper over
    /// this, so the two entry points can't drift apart. Reach for the style when
    /// the button owns its label; call this directly when the background wraps a
    /// label inside a `.plain` button.
    ///
    /// Figma specifies a 64px BACKGROUND_BLUR on "Button Secondary". UIKit/SwiftUI
    /// don't expose a settable pixel radius for a backdrop blur, so we use
    /// `.ultraThinMaterial` (a strong frosted blur) to match the intent.
    func secondaryButtonBackground() -> some View {
        background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                AppColors.btnSecondary          // translucent light tint over the blur
            }
        }
        .clipShape(Capsule())
    }
}
