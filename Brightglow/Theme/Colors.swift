import SwiftUI

// Semantic layer over the 8-color palette in design/tokens.json (Figma source of
// truth): white, gray50, gray20, bg, bgSecondary, accent, orange, magenta.
// Every value below resolves to one of those eight tokens. Run `npm run tokens`
// to refresh DesignTokens from the source.
struct AppColors {
    // ── Backgrounds ──────────────────────────────────────────────────────────
    static let bg              = DesignTokens.colorBg
    static let bgPrimary       = DesignTokens.colorBg
    static let bgSurface       = DesignTokens.colorBg
    static let bgOverlay       = DesignTokens.colorBgSecondary
    static let surface         = DesignTokens.colorBg
    static let cardFallback    = DesignTokens.colorGray20

    // ── Text ─────────────────────────────────────────────────────────────────
    static let textPrimary     = DesignTokens.colorWhite
    static let textSecondary   = DesignTokens.colorGray50

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

    // ── Border ───────────────────────────────────────────────────────────────
    static let border          = DesignTokens.colorGray20

    // ── Search bar ───────────────────────────────────────────────────────────
    static let searchBg        = DesignTokens.colorBgSecondary
    static let searchBorder    = DesignTokens.colorGray20

    // ── Shutter button ────────────────────────────────────────────────────────
    static let shutterBg       = DesignTokens.colorGray20
    static let shutterBorder   = DesignTokens.colorWhite
    static let shutterRing     = DesignTokens.colorGray20

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
