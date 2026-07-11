import SwiftUI
import AVFoundation

struct CameraScreen: View {
    @ObservedObject var camera: CameraViewModel

    var body: some View {
        ZStack {
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            } else {
                // No camera access yet → black viewfinder (Figma: Main – Before
                // permissions). The dark camera-icon shutter on the landing
                // (MainScreen) is the "grant access" CTA that sits over this.
                Color.black.ignoresSafeArea()
            }
        }
    }
}
