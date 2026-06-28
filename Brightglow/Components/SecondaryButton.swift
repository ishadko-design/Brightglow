import SwiftUI

extension View {
    /// Frosted background for a secondary button (large or small): a background
    /// blur under the translucent light fill, clipped to a capsule.
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
