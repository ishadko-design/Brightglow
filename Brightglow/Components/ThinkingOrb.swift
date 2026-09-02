import SwiftUI

/// A compact "thinking orb": dots orbiting on tilted elliptical paths, for
/// loading / working states — a calmer, more modern take than a spinner.
///
/// SwiftUI reimplementation of the idea behind the open-source `thinking-orbs`
/// (github.com/Jakubantalik/thinking-orbs, MIT) — the original is React + HTML
/// Canvas; this draws the same orbiting-particles look natively with SwiftUI's
/// `Canvas` + `TimelineView`, so it costs nothing extra and matches the app's
/// style. Front-facing dots (coming toward the viewer) render larger and
/// brighter, which reads as a rotating 3-D orb.
struct ThinkingOrb: View {
    var size: CGFloat = 20
    var color: Color = .white
    /// Speed of the orbit in radians/second.
    var speed: Double = 1.15

    /// Orbital rings, each an ellipse rotated to a different angle so the dots
    /// trace tilted paths around a common centre.
    private let rings = 3
    private let dotsPerRing = 9
    /// How flat each ellipse is (its minor/major ratio) — the "tilt".
    private let flatten = 0.42

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, sz in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let radius = Double(min(sz.width, sz.height)) / 2 * 0.82
                let dotBase = max(1, Double(size) * 0.055)

                for ring in 0 ..< rings {
                    let phi = Double(ring) / Double(rings) * .pi   // ring orientation
                    let cphi = cos(phi), sphi = sin(phi)
                    for d in 0 ..< dotsPerRing {
                        let theta = t * speed
                            + Double(d) / Double(dotsPerRing) * 2 * .pi
                            + Double(ring) * 0.7
                        // Point on the flat ellipse, then rotated into the ring's tilt.
                        let lx = radius * cos(theta)
                        let ly = radius * flatten * sin(theta)
                        let x = Double(c.x) + lx * cphi - ly * sphi
                        let y = Double(c.y) + lx * sphi + ly * cphi
                        // Depth cue: sin(theta) > 0 means the dot is on the near side.
                        let depth = (sin(theta) + 1) / 2                // 0 back … 1 front
                        let dr = dotBase * (0.55 + 0.75 * depth)
                        let op = 0.25 + 0.75 * depth
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x - dr, y: y - dr, width: dr * 2, height: dr * 2)),
                            with: .color(color.opacity(op))
                        )
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
