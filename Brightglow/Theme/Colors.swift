import SwiftUI

// Semantic layer over the palette in design/tokens.json (Figma source of truth):
// white, gray60, gray50, gray20, gray10, gray05, bg, bgSecondary, accent, orange,
// green, magenta. Every value below resolves to one of those tokens. Run
// `npm run tokens` to refresh DesignTokens from the source.
struct AppColors {
    // ── Backgrounds ──────────────────────────────────────────────────────────
    static let bg              = DesignTokens.colorBg
    static let bgPrimary       = DesignTokens.colorBg
    static let bgSurface       = DesignTokens.colorBg
    static let bgOverlay       = DesignTokens.colorBgSecondary
    static let surface         = DesignTokens.colorBg
    static let cardFallback    = DesignTokens.colorGray20

    /// Card surface and the segmented-tab track (Figma `gray05`). The business
    /// dashboard/settings cards and the Dashboard|Settings pill sit on this.
    static let cardSurface     = DesignTokens.colorGray05

    // ── Text ─────────────────────────────────────────────────────────────────
    static let textPrimary     = DesignTokens.colorWhite
    // Bumped from gray50 → gray60 for readability (secondary text was too dim).
    static let textSecondary   = DesignTokens.colorGray60

    // ── Accent / primary button (flat solid blue) ────────────────────────────
    static let accentStart     = DesignTokens.colorAccent
    static let accentEnd       = DesignTokens.colorAccent
    static let accentGradient  = LinearGradient(
        colors: [DesignTokens.colorAccent, DesignTokens.colorAccent],
        startPoint: .leading, endPoint: .trailing
    )

    // ── Generic CTA ──────────────────────────────────────────────────────────
    static let ctaBlue         = DesignTokens.colorAccent
    static let ctaPrimary      = DesignTokens.colorAccent
    static let ctaSecondary    = DesignTokens.colorGray20
    static let ctaText         = DesignTokens.colorWhite

    // ── Stars ─────────────────────────────────────────────────────────────────
    static let starFilled      = DesignTokens.colorOrange
    static let starEmpty       = DesignTokens.colorGray20

    // ── Toggle ────────────────────────────────────────────────────────────────
    /// "Accepting new work" in the business dashboard, on state (Figma `green`).
    static let toggleOn        = DesignTokens.colorGreen

    // ── Border ───────────────────────────────────────────────────────────────
    static let border          = DesignTokens.colorGray20

    // ── Subtle fill (tinted surface behind icons/tiles) ───────────────────────
    static let fillSubtle      = DesignTokens.colorGray10

    // ── Search bar ───────────────────────────────────────────────────────────
    static let searchBg        = DesignTokens.colorBgSecondary
    static let searchBorder    = DesignTokens.colorGray20

    // ── Profile icon ──────────────────────────────────────────────────────────
    static let iconBg          = DesignTokens.colorBgSecondary

    // ── Card gradient (used for contractor card fade) ─────────────────────────
    static let gradientTop     = DesignTokens.colorBg.opacity(0)
    static let gradientBottom  = DesignTokens.colorBg

    // ── Drawing stroke ────────────────────────────────────────────────────────
    static let drawingStroke   = DesignTokens.colorMagenta

    // ── Swipe screen buttons ──────────────────────────────────────────────────
    static let btnPrimary      = DesignTokens.colorAccent
    static let btnPrimaryText  = DesignTokens.colorWhite
    static let btnSecondary    = DesignTokens.colorGray20
    static let btnSecondaryText = DesignTokens.colorWhite

    // ── Pagination dots ───────────────────────────────────────────────────────
    static let dotActive       = DesignTokens.colorWhite
    static let dotInactive     = DesignTokens.colorGray20

    // ── Sheet drag handle ─────────────────────────────────────────────────────
    static let handle          = DesignTokens.colorGray20
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
