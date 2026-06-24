import SwiftUI

// Figma design system — node 268:564
// Only these five text styles are used across the app.

extension Font {
    /// H1 — Lato ExtraBold 800, 44pt. Display / brand.
    static let h1: Font = .custom("Lato-ExtraBold", size: 44)
    /// H2 — Lato ExtraBold 800, 24pt. Screen titles.
    static let h2: Font = .custom("Lato-ExtraBold", size: 24)
    /// H3 — Lato Bold 700, 18pt. Cards, buttons, section heads.
    static let h3: Font = .custom("Lato-Bold", size: 18)
    /// H4 — Lato Bold 700, 14pt. Small / dense header actions.
    static let h4: Font = .custom("Lato-Bold", size: 14)
    /// Body — Poppins Light 300, 17pt. Primary body copy.
    static let bodyLight: Font = .custom("Poppins-Light", size: 17)
    /// Body 2 — Poppins Light 300, 14pt. Secondary / captions.
    static let bodySmall: Font = .custom("Poppins-Light", size: 14)
}
