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
                Color(hex: "#1A1A1A").ignoresSafeArea()
                if camera.permissionDenied {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Camera access needed")
                            .font(.h3)
                            .foregroundStyle(.white.opacity(0.5))
                        Button("Open Settings", action: camera.openSettings)
                            .font(.bodyLight)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
    }
}
