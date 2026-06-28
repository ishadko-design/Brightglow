import SwiftUI

/// Shared header backdrop, used across screens so every header reads the same.
///
/// Figma (node 345-734, "Blurred bg"): a vertical black→transparent gradient with
/// a LAYER_BLUR of 12, drawn oversized so its blurred edges sit off the canvas.
/// We keep that layer blur and drop the BACKGROUND_BLUR (frosted glass).
///
/// Layout-neutral: a fixed-size `Color.clear` anchors the footprint, and the
/// gradient is an overlay drawn oversized and pulled up with `.offset` to cover
/// the status bar. We deliberately avoid `.ignoresSafeArea` here — applied inside
/// a `.background`, it propagates to the enclosing GeometryReader and offsets the
/// whole screen. `.offset` extends the visuals upward without touching layout.
struct BlurredHeaderBackground: View {
    var height: CGFloat = 140
    private let overscan: CGFloat = 40
    private let topCover: CGFloat = 80   // pulls the gradient up over the status bar

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: .black,               location: 0.0),
                        .init(color: .black.opacity(0.7),  location: 0.4),
                        .init(color: .black.opacity(0.3),  location: 0.72),
                        .init(color: .clear,               location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height + topCover)
                .padding(.horizontal, -overscan)
                .blur(radius: 18)
                .offset(y: -topCover)
            }
            .allowsHitTesting(false)
    }
}
