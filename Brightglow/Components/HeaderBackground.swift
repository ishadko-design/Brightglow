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

/// Shared footer backdrop — mirrors the header scrim, flipped vertically: a
/// black→transparent gradient drawn TALL (up past the top of the viewport) and
/// softly layer-blurred (24pt), with NO backdrop blur. The fade starts
/// off-screen, so there is never a visible band edge floating over content;
/// black holds strong through the bottom (like the header holds it at the top)
/// so the CTAs sit on darkness. The gradient also runs past the bottom edge of
/// the screen, so the blur's faded bottom edge falls off-screen and the visible
/// bottom stays solid black.
///
/// Layout-neutral: a fixed-size `Color.clear` anchors the footprint (strong
/// zone + bottom inset); the oversized gradient is drawn in the overlay /
/// background and offset downward, so it can never inflate the footer or push
/// buttons off-screen. The blurred gradient is drawn oversized horizontally so
/// the blur's side edges fall off-screen instead of leaving faded strips.
struct BlurredFooterBackground: View {
    /// Strong-black zone at the bottom (CTAs + home indicator).
    var height: CGFloat = 160
    /// How far the fade extends upward — past the top of the viewport, so its
    /// start is never visible.
    var topExtend: CGFloat = 800
    /// How far the gradient continues past the bottom edge of the screen.
    var bottomExtend: CGFloat = 300
    /// The screen's safe-area bottom inset — the black holds solid through it.
    var bottomInset: CGFloat = 0

    private var totalHeight: CGFloat { topExtend + height + bottomExtend + bottomInset }
    /// Gradient location where the fade begins (everything above is clear).
    private var fadeStart: CGFloat { topExtend / totalHeight }
    /// Gradient location where the black turns solid (stays solid past the
    /// screen's bottom edge).
    private var solidStart: CGFloat { fadeStart + 0.08 }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height + bottomInset)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.35), location: fadeStart),
                        .init(color: .black.opacity(0.85), location: solidStart),
                        .init(color: .black.opacity(0.85), location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(maxWidth: .infinity)
                .frame(height: totalHeight)
                .padding(.horizontal, -sideOverscan)
                .blur(radius: blurRadius)
                .offset(y: bottomExtend)
            }
            .allowsHitTesting(false)
    }

    /// Layer blur softening the fade (the header's recipe, no backdrop blur).
    private let blurRadius: CGFloat = 24
    /// Horizontal overscan (≥ the blur radius) so the blurred side edges fall
    /// off the screen rather than showing as faded strips at the margins.
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
