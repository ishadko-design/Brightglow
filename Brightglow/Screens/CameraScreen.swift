import SwiftUI
import AVFoundation

struct CameraScreen: View {
    @ObservedObject var camera: CameraViewModel
    /// Zoom the pinch started from — the gesture reports magnification relative
    /// to its own start, so without this every pinch would jump back to 1×.
    @State private var zoomAtPinchStart: CGFloat = 1

    var body: some View {
        ZStack {
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    // Pinch anywhere on the exposed viewfinder to zoom.
                    .gesture(
                        MagnifyGesture()
                            .onChanged { camera.setZoom(zoomAtPinchStart * $0.magnification) }
                            .onEnded { _ in zoomAtPinchStart = camera.zoomFactor }
                    )
            } else {
                // No camera access yet → black viewfinder (Figma: Main – Before
                // permissions). The dark camera-icon shutter on the landing
                // (MainScreen) is the "grant access" CTA that sits over this.
                Color.black.ignoresSafeArea()
            }
        }
    }
}
