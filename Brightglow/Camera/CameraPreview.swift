import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        // Fill the tall screen edge-to-edge (a centered crop of the 4:3 feed) so
        // the viewfinder has no letterbox bars. `.resizeAspect` fit the whole 4:3
        // frame instead, which black-bars the top and bottom on a phone screen.
        // Preview gravity is cosmetic only — the captured photo is the full 4:3
        // frame regardless, so the classifier still gets the wider image.
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
