import SwiftUI

/// Left-to-right wrapping layout — lays children in rows, wrapping to the next
/// line only when the current row runs out of width. Used for the tag chips +
/// text field in the input bar, so a chip and the field share one line and only
/// wrap when they genuinely don't fit.
///
/// `stretchLast` expands the final child (the text field) to fill the remaining
/// width of its row, so it stays tappable and left-aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var stretchLast: Bool = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        solve(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let plan = solve(subviews, maxWidth: bounds.width)
        for item in plan.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + item.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: item.width, height: item.height)
            )
        }
    }

    // MARK: - Layout solver

    private struct Item { let index: Int; let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }

    private func solve(_ subviews: Subviews, maxWidth: CGFloat) -> (items: [Item], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Group indices into rows by intrinsic width.
        var rows: [[Int]] = []
        var current: [Int] = []
        var rowW: CGFloat = 0
        for i in subviews.indices {
            let w = sizes[i].width
            if !current.isEmpty, rowW + spacing + w > maxWidth {
                rows.append(current); current = []; rowW = 0
            }
            rowW += (current.isEmpty ? 0 : spacing) + w
            current.append(i)
        }
        if !current.isEmpty { rows.append(current) }

        let lastIndex = subviews.indices.last
        var items: [Item] = []
        var y: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for row in rows {
            // Resolve each item's width; stretch the final subview to fill its row.
            var widths = row.map { sizes[$0].width }
            if stretchLast, row.last == lastIndex, let last = row.last {
                let used = row.dropLast().reduce(CGFloat(0)) { $0 + sizes[$1].width + spacing }
                widths[widths.count - 1] = max(maxWidth - used, sizes[last].width)
            }
            // Row height accounts for the (possibly stretched) last field wrapping.
            var heights = row.map { sizes[$0].height }
            if stretchLast, row.last == lastIndex, let last = row.last {
                heights[heights.count - 1] = subviews[last]
                    .sizeThatFits(ProposedViewSize(width: widths[widths.count - 1], height: nil)).height
            }
            let rowHeight = heights.max() ?? 0

            var x: CGFloat = 0
            for (j, idx) in row.enumerated() {
                // Vertically center each item within its row.
                let itemY = y + (rowHeight - heights[j]) / 2
                items.append(Item(index: idx, x: x, y: itemY, width: widths[j], height: heights[j]))
                x += widths[j] + spacing
            }
            maxRowWidth = max(maxRowWidth, x - spacing)
            y += rowHeight + spacing
        }

        let totalHeight = max(y - spacing, 0)
        return (items, CGSize(width: min(maxRowWidth, maxWidth), height: totalHeight))
    }
}
