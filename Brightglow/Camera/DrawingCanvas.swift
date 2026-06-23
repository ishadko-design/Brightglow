import SwiftUI

struct DrawnPath {
    var points: [CGPoint] = []
}

struct DrawingCanvas: View {
    @Binding var paths: [DrawnPath]
    /// Fires when a stroke ends, with the stroke's bounding box in view coords.
    var onSelection: (CGRect) -> Void = { _ in }
    @State private var currentPath = DrawnPath()

    var body: some View {
        Canvas { context, size in
            for path in paths + [currentPath] {
                guard path.points.count > 1 else { continue }
                var swiftPath = Path()
                swiftPath.move(to: path.points[0])
                for point in path.points.dropFirst() {
                    swiftPath.addLine(to: point)
                }
                context.stroke(swiftPath, with: .color(AppColors.drawingStroke), style: StrokeStyle(
                    lineWidth: 7,
                    lineCap: .round,
                    lineJoin: .round
                ))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    currentPath.points.append(value.location)
                }
                .onEnded { _ in
                    let pts = currentPath.points
                    paths.append(currentPath)
                    currentPath = DrawnPath()
                    if pts.count > 1 {
                        let xs = pts.map(\.x), ys = pts.map(\.y)
                        let box = CGRect(x: xs.min()!, y: ys.min()!,
                                         width: xs.max()! - xs.min()!,
                                         height: ys.max()! - ys.min()!)
                        onSelection(box)
                    }
                }
        )
    }
}
