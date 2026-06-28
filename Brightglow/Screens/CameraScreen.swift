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
                // No camera access yet → black viewfinder. The user taps the
                // camera to grant access (Figma: "0. Main screen - no permissions").
                Color.black.ignoresSafeArea()

                VStack(spacing: 20) {
                    // Circle-ring camera button (Figma).
                    Button(action: { Task { await camera.requestPermissionAndStart() } }) {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 3)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 80, height: 80)
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.permissionDenied)

                    if camera.permissionDenied {
                        VStack(spacing: 4) {
                            Text("Camera access is off")
                                .font(.bodyLight)
                                .foregroundStyle(.white.opacity(0.7))
                            Button("Open Settings", action: camera.openSettings)
                                .font(.bodyLight)
                                .foregroundStyle(AppColors.accentStart)
                        }
                    } else {
                        Text("Take a picture and explain your\ntask for a smart estimate")
                            .font(.bodyLight)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
        }
    }
}
