import SwiftUI

/// Shared header backdrop, used across screens so every header reads the same.
///
/// Gradient-only: a vertical black→transparent scrim, drawn oversized and softly
/// blurred so BOTH ends die to nothing with no hard edge. We dropped the frosted
/// `.ultraThinMaterial` blur — over bright content it washed out to gray/white and
/// left a visible light line where its masked edge ended.
///
/// Two intensities:
///  • `.dark`  — content screens (results list, gallery, draw-over) whose header
///    sits over bright photos and must stay readable: a stronger scrim.
///  • `.light` — the camera landing, where the live viewfinder is the point and a
///    heavy scrim just greys it out: a light touch that fades away fast.
///
/// Layout-neutral: a fixed-size `Color.clear` anchors the footprint, and the
/// gradient is an overlay drawn oversized and pulled up with `.offset` to cover
/// the status bar. We deliberately avoid `.ignoresSafeArea` here — applied inside
/// a `.background`, it propagates to the enclosing GeometryReader and offsets the
/// whole screen. `.offset` extends the visuals upward without touching layout.
struct BlurredHeaderBackground: View {
    enum Style { case dark, light }

    // Default is the light scrim; the darker, blurred board is opt-in (`.dark`) and
    // used ONLY where the header carries text over content that must stay readable
    // — currently just the results list. Every other screen uses `.light`.
    var style: Style = .light
    var height: CGFloat = 132

    /// How far above the header's top edge the gradient is drawn. `.dark` reaches
    /// FAR past the screen top with its black held solid up there, so the blurred
    /// top edge samples black (not the empty space above it) and there is no light
    /// gap over the status bar. `.light` needs only enough to cover the status bar.
    private var topCover: CGFloat { style == .dark ? 130 : 60 }

    /// Softening blur. `.dark` uses a slightly harsher one so the scrim reads as a
    /// solid, modifiable backdrop; `.light` stays gentle.
    private var blurRadius: CGFloat { style == .dark ? 16 : 12 }

    /// Black→transparent stops for the chosen intensity. Both end at `.clear`, so
    /// the gradient itself has no hard edge; the trailing `.blur` only softens it.
    /// The `.dark` stops HOLD black across the top (through the off-screen overscan,
    /// the status bar, and the title) before fading, so the whole readable region
    /// stays dark over bright photos.
    private var stops: [Gradient.Stop] {
        switch style {
        case .dark:
            return [
                .init(color: .black.opacity(0.8),  location: 0.0),
                .init(color: .black.opacity(0.75), location: 0.6),
                .init(color: .black.opacity(0.3),  location: 0.82),
                .init(color: .clear,               location: 1.0),
            ]
        case .light:
            return [
                .init(color: .black.opacity(0.5),  location: 0.0),
                .init(color: .black.opacity(0.16), location: 0.45),
                .init(color: .clear,               location: 1.0),
            ]
        }
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    // Real backdrop blur — frosts the content (list photos) scrolling
                    // beneath the header, iOS Photos-style. Dark styles only: over the
                    // live camera a frost just greys the viewfinder. It sits UNDER the
                    // dark scrim, so the material's own greyness is covered rather than
                    // washing out; masked to fade out well before the scrim ends so its
                    // edge is never visible.
                    if style == .dark {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .frame(height: height + topCover)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0.0),
                                        .init(color: .black, location: 0.62),
                                        .init(color: .clear, location: 0.82),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .padding(.horizontal, -sideOverscan)
                            .offset(y: -topCover)
                    }
                    LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
                        .frame(height: height + topCover)
                        // Extend past the left/right screen edges so the blur's soft
                        // horizontal edges sit off-canvas — otherwise it leaves lightened
                        // transparent strips down the sides.
                        .padding(.horizontal, -sideOverscan)
                        // Last stop is already `.clear`, so no hard bottom edge; the blur
                        // only softens the fade — and, with the dark black held above the
                        // screen, keeps the top solid instead of lightening it.
                        .blur(radius: blurRadius)
                        .offset(y: -topCover)
                }
            }
            .allowsHitTesting(false)
    }

    /// Horizontal overscan (≥ the blur radius) so the blurred side edges fall off
    /// the screen rather than showing as faded strips at the left/right margins.
    private let sideOverscan: CGFloat = 40
}

/// Footer scrim — `BlurredHeaderBackground(.dark)` flipped vertically and made
/// much smaller: clear at the top, ramping to black at the bottom, drawn
/// oversized and layer-blurred with the SAME blur radius as the dark header
/// (16), no backdrop material — the `.ultraThinMaterial`/`background-blur`
/// approximation tinted the photos and was rejected. Same stop shape as the
/// dark header, mirrored (per Igor: the Figma 2-stop linear ramp never got dark
/// enough behind the pills once the solid #131315 CTA strip was removed).
///
/// The single detail that makes it read clean instead of washed: like the
/// header holds its black solid FAR past the screen's top edge (`topCover` +
/// `.offset(-topCover)`) so its blur always samples black, the footer holds its
/// black solid past the BOTTOM edge (`bottomCover` + `.offset(+bottomCover)`).
/// Without that, `.blur(radius: 16)` samples the empty/transparent area beyond
/// the gradient's own bottom edge and pulls the backdrop back toward transparent
/// exactly where the buttons sit — washing it out, lifting the dark band off the
/// bottom (buttons look "elevated"), and feathering into soft corner glows at
/// the overscanned side edges.
///
/// Layout-neutral: a fixed-size `Color.clear` anchors the footprint and CROPS
/// the overlay to `height` at the bottom of the screen; the gradient is drawn
/// taller and offset DOWN so only its upper fade shows. Never intercepts
/// touches, and can never inflate the footer or push buttons off-screen.
struct FigmaFooterScrim: View {
    /// Visible scrim height (the crop). Figma: list footer 125, gallery 124.
    var height: CGFloat = 124

    /// How far the solid-black bottom of the gradient is held BELOW the footer's
    /// bottom edge, so the layer blur samples black there instead of the empty
    /// area beyond the edge — the footer mirror of the header's `topCover`.
    private let bottomCover: CGFloat = 120

    /// Mirror of the dark header's black→clear stops (0.8 held, 0.75, 0.3, clear)
    /// flipped so clear is at the top and the held black is at the bottom.
    private var stops: [Gradient.Stop] {
        [
            .init(color: .clear,               location: 0.0),
            .init(color: .black.opacity(0.3),  location: 0.18),
            .init(color: .black.opacity(0.75), location: 0.4),
            .init(color: .black.opacity(0.8),  location: 1.0),
        ]
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .bottom) {
                LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
                    .frame(height: height + bottomCover)
                    // Overscan the sides (≥ blur radius) so the blurred left/right
                    // edges fall off-screen rather than showing as faded strips.
                    .padding(.horizontal, -sideOverscan)
                    // Same blur as the dark header (16), not Figma's footer 24 —
                    // "same treatment as the top blurred gradient" (Igor).
                    .blur(radius: 16)
                    // Hold the solid black past the bottom edge so the blur never
                    // samples transparency behind the buttons.
                    .offset(y: bottomCover)
            }
            .allowsHitTesting(false)
    }

    private let sideOverscan: CGFloat = 40
}

/// Frosted-glass background for the secondary pills: the Figma "Background
/// blur" on the CTA pills — a live backdrop blur under the white-at-20% tint,
/// clipped to the pill shape. The photo behind the pill visibly frosts instead
/// of showing through flat. (The gallery's Call button already uses this
/// recipe; this shares it with the list's pills.)
struct FrostedPillBackground: View {
    var body: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(AppColors.btnSecondary))
    }
}
