import SwiftUI

/// Scrollable 2-column card grid used as bottom-sheet content. Renders a title
/// (with an optional back chevron for drilled-in grids) above a `TaskCard`
/// grid, and reports scroll-top state so the sheet knows when a downward drag
/// should collapse it.
struct GridSheet<Content: View>: View {
    let title: String
    var onBack: (() -> Void)? = nil
    /// Updated on every scroll frame — true only when content is at the very top.
    @Binding var isScrolledToTop: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {

                // Header row — optional back chevron + title
                HStack(spacing: 8) {
                    if let onBack {
                        Button(action: onBack) {
                            // Match the app-wide back control (gallery, contractor
                            // list, draw mode): arrow.left, 18pt semibold.
                            Image(systemName: "arrow.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(AppColors.textPrimary)
                                .iconTapTarget()
                        }
                        .padding(.leading, -10)   // align the glyph (not its tap box) to the margin
                    }
                    Text(title)
                        .font(.h2)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 16)

                // 2-column grid
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 16
                ) {
                    content
                }
                .padding(.horizontal, 16)
                // Extra clearance so the last cards scroll clear of the search
                // input / gradient at the bottom instead of hiding behind it.
                .padding(.bottom, 280)
            }
            .padding(.top, 4)
        }
        // onScrollGeometryChange fires on every scroll frame (not just layout passes),
        // giving us a real-time, accurate "is at top" signal.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y <= 0
        } action: { _, atTop in
            isScrolledToTop = atTop
        }
    }
}
