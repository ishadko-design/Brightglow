import SwiftUI

// Token-backed values (bg, accents, text, stars, dots, border) come from
// DesignTokens, generated from design/tokens.json — the Figma-synced source of
// truth. App-specific extras below stay literal. Run `npm run tokens` to refresh.
struct AppColors {
    // ── Backgrounds ──────────────────────────────────────────────────────────
    static let bg              = DesignTokens.colorBg
    static let bgPrimary       = DesignTokens.colorBg
    static let bgSurface       = DesignTokens.colorBg
    static let bgOverlay       = Color.black.opacity(0.55)
    static let surface         = DesignTokens.colorBg
    static let cardFallback    = DesignTokens.colorCardFallback

    // ── Text ─────────────────────────────────────────────────────────────────
    static let textPrimary     = DesignTokens.colorTextPrimary
    static let textSecondary   = DesignTokens.colorTextSecondary

    // ── Accent / primary button (gradient) ───────────────────────────────────
    static let accentStart     = DesignTokens.colorAccentStart
    static let accentEnd       = DesignTokens.colorAccentEnd
    static let accentGradient  = LinearGradient(
        colors: [DesignTokens.colorAccentStart, DesignTokens.colorAccentEnd],
        startPoint: .leading, endPoint: .trailing
    )

    // ── Generic CTA ──────────────────────────────────────────────────────────
    static let ctaBlue         = DesignTokens.colorCtaBlue     // primary blue (Figma)
    static let ctaPrimary      = DesignTokens.colorAccentStart // fallback solid
    static let ctaSecondary    = DesignTokens.colorCtaSecondary
    static let ctaText         = Color.white

    // ── Stars ─────────────────────────────────────────────────────────────────
    static let starFilled      = DesignTokens.colorStarFilled
    static let starEmpty       = DesignTokens.colorStarEmpty

    // ── Border ───────────────────────────────────────────────────────────────
    static let border          = DesignTokens.colorBorder

    // ── Search bar ───────────────────────────────────────────────────────────
    static let searchBg        = Color(hex: "#1E1E22").opacity(0.6)   // tinted base under blur
    static let searchBorder    = Color.white.opacity(0.3)

    // ── Shutter button ────────────────────────────────────────────────────────
    static let shutterBg       = Color.white.opacity(0.18)
    static let shutterBorder   = Color.white
    static let shutterRing     = Color.white.opacity(0.3)

    // ── Profile icon ──────────────────────────────────────────────────────────
    static let iconBg          = Color.black.opacity(0.1)

    // ── Card gradient (used for contractor card fade) ─────────────────────────
    static let gradientTop     = Color(hex: "#131315").opacity(0)
    static let gradientBottom  = Color(hex: "#131315")

    // ── Drawing stroke ────────────────────────────────────────────────────────
    static let drawingStroke   = Color(hex: "#FF00BB")

    // ── Swipe screen buttons ──────────────────────────────────────────────────
    static let btnPrimary      = Color(hex: "#0039F5")        // solid fallback
    static let btnPrimaryText  = Color.white
    static let btnSecondary    = Color(hex: "#333640")
    static let btnSecondaryText = Color.white

    // ── Pagination dots ───────────────────────────────────────────────────────
    static let dotActive       = DesignTokens.colorDotActive
    static let dotInactive     = DesignTokens.colorDotInactive

    // ── Sheet drag handle ─────────────────────────────────────────────────────
    static let handle          = Color.white.opacity(0.12)
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
