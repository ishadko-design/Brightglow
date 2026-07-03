import SwiftUI

struct DrawnPath {
    var points: [CGPoint] = []
}

extension UIImage {
    /// Bakes the drawn strokes into the photo's actual pixels, so what gets
    /// sent matches what the user saw on screen. `paths` are recorded in
    /// DrawModeView's view-space coordinates (the photo shown scaledToFill
    /// + clipped in `viewSize`) — same mapping as ImageClassifier's `crop`.
    func flattened(withStrokes paths: [DrawnPath], viewSize: CGSize) -> UIImage {
        guard viewSize.width > 0, viewSize.height > 0, !paths.isEmpty else { return self }
        let img = normalizedUp()
        let isz = img.size
        let scale = max(viewSize.width / isz.width, viewSize.height / isz.height)
        let offsetX = (isz.width * scale - viewSize.width) / 2
        let offsetY = (isz.height * scale - viewSize.height) / 2

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = img.scale
        return UIGraphicsImageRenderer(size: isz, format: fmt).image { ctx in
            img.draw(in: CGRect(origin: .zero, size: isz))
            ctx.cgContext.setStrokeColor(UIColor(AppColors.drawingStroke).cgColor)
            ctx.cgContext.setLineWidth(7 / scale)
            ctx.cgContext.setLineCap(.round)
            ctx.cgContext.setLineJoin(.round)
            for path in paths {
                guard path.points.count > 1 else { continue }
                let imagePoints = path.points.map {
                    CGPoint(x: ($0.x + offsetX) / scale, y: ($0.y + offsetY) / scale)
                }
                ctx.cgContext.move(to: imagePoints[0])
                for pt in imagePoints.dropFirst() { ctx.cgContext.addLine(to: pt) }
                ctx.cgContext.strokePath()
            }
        }
    }
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
