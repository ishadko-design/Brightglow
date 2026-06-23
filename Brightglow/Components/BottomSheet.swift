import SwiftUI

enum SheetDetent: Equatable {
    case collapsed   // only the handle visible (~80pt)
    case mid         // default — camera visible + dimmed above (~400pt)
    case full        // full screen
}

struct BottomSheet<Content: View>: View {
    @Binding var detent: SheetDetent
    var contentIsAtTop: Bool = true
    var collapsedHeight: CGFloat = 80
    var midHeight: CGFloat = 400
    var fullTopInset: CGFloat = 0   // gap left above the sheet when fully expanded
    let content: Content

    init(
        detent: Binding<SheetDetent>,
        contentIsAtTop: Bool = true,
        collapsedHeight: CGFloat = 80,
        midHeight: CGFloat = 400,
        fullTopInset: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self._detent = detent
        self.contentIsAtTop = contentIsAtTop
        self.collapsedHeight = collapsedHeight
        self.midHeight = midHeight
        self.fullTopInset = fullTopInset
        self.content = content()
    }

    @GestureState private var dragOffset: CGFloat = 0

    private func targetOffset(for d: SheetDetent, in total: CGFloat) -> CGFloat {
        switch d {
        case .collapsed: return total - collapsedHeight
        case .mid:       return total - midHeight
        case .full:      return fullTopInset
        }
    }

    private func currentOffset(in total: CGFloat) -> CGFloat {
        let base = targetOffset(for: detent, in: total)
        let raw  = base + dragOffset
        return max(fullTopInset, min(total - collapsedHeight, raw))
    }

    var body: some View {
        GeometryReader { geo in
            let total  = geo.size.height
            let offset = currentOffset(in: total)

            VStack(spacing: 0) {
                // ── Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 44, height: 5)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                AppColors.bgSurface
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .ignoresSafeArea(edges: .bottom)
            )
            .offset(y: offset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .updating($dragOffset) { value, state, _ in
                        let dy = value.translation.height
                        switch detent {
                        case .collapsed:
                            // Only allow upward drag to expand
                            state = min(0, dy)
                        case .mid:
                            // Up = expand; down = collapse (always allowed from mid)
                            state = dy
                        case .full:
                            // Down only when content is scrolled to top
                            if dy > 0 { state = contentIsAtTop ? dy : 0 }
                            else       { state = dy }
                        }
                    }
                    .onEnded { value in
                        let v = value.predictedEndTranslation.height
                        let t = value.translation.height
                        withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) {
                            switch detent {
                            case .collapsed:
                                if v < -250 || t < -60 { detent = .full }
                            case .mid:
                                if      v < -250 || t < -60 { detent = .full }
                                else if v >  250 || t >  60 { detent = .collapsed }
                            case .full:
                                if contentIsAtTop && (v > 250 || t > 60) { detent = .collapsed }
                            }
                        }
                    }
            )
            .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: detent)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}
