import SwiftUI

/// App-wide rule: every tappable icon (input-bar glyphs, toolbar buttons, etc.)
/// sits inside a fixed 44×44 boundary — consistent touch target across the app.
struct IconTapTarget: ViewModifier {
    static let size: CGFloat = 44
    func body(content: Content) -> some View {
        content.frame(width: Self.size, height: Self.size)
    }
}

extension View {
    /// Wrap an icon in the standard 44×44 tap boundary.
    func iconTapTarget() -> some View { modifier(IconTapTarget()) }
}
