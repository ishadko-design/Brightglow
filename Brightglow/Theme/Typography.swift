import SwiftUI

// Figma design system — node 268:564
// Only these five text styles are used across the app.

// Values are generated from design/tokens.json (DesignTokens). Edit tokens +
// run `npm run tokens`, don't hardcode sizes here.
extension Font {
    /// H1 — Lato ExtraBold 800, 44pt. Display / brand.
    static let h1: Font = DesignTokens.typographyH1
    /// H2 — Lato ExtraBold 800, 24pt. Screen titles.
    static let h2: Font = DesignTokens.typographyH2
    /// H3 — Lato Bold 700, 18pt. Cards, buttons, section heads.
    static let h3: Font = DesignTokens.typographyH3
    /// H4 — Lato Bold 700, 14pt. Small / dense header actions.
    static let h4: Font = DesignTokens.typographyH4
    /// Body — Poppins Light 300, 17pt. Primary body copy.
    static let bodyLight: Font = DesignTokens.typographyBodyLight
    /// Body 2 — Poppins Light 300, 14pt. Secondary / captions.
    static let bodySmall: Font = DesignTokens.typographyBodySmall
}
