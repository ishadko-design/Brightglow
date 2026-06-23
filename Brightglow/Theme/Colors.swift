import SwiftUI

struct AppColors {
    // ── Backgrounds ──────────────────────────────────────────────────────────
    static let bg              = Color(hex: "#131315")
    static let bgPrimary       = Color(hex: "#131315")
    static let bgSurface       = Color(hex: "#131315")
    static let bgOverlay       = Color.black.opacity(0.55)
    static let surface         = Color(hex: "#131315")
    static let cardFallback    = Color(hex: "#1E1E22")

    // ── Text ─────────────────────────────────────────────────────────────────
    static let textPrimary     = Color.white
    static let textSecondary   = Color.white.opacity(0.5)

    // ── Accent / primary button (gradient) ───────────────────────────────────
    static let accentStart     = Color(hex: "#0039F5")
    static let accentEnd       = Color(hex: "#1528FF")
    static let accentGradient  = LinearGradient(
        colors: [Color(hex: "#0039F5"), Color(hex: "#1528FF")],
        startPoint: .leading, endPoint: .trailing
    )

    // ── Generic CTA ──────────────────────────────────────────────────────────
    static let ctaBlue         = Color(hex: "#617AFF")   // primary blue (Figma)
    static let ctaPrimary      = Color(hex: "#0039F5")   // fallback solid
    static let ctaSecondary    = Color(hex: "#333640")
    static let ctaText         = Color.white

    // ── Stars ─────────────────────────────────────────────────────────────────
    static let starFilled      = Color(hex: "#D3A500")
    static let starEmpty       = Color.white.opacity(0.2)

    // ── Border ───────────────────────────────────────────────────────────────
    static let border          = Color.white.opacity(0.12)

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
    static let dotActive       = Color.white
    static let dotInactive     = Color.white.opacity(0.3)

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
