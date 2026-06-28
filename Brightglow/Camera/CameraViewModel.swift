import AVFoundation
import SwiftUI
import Combine

@MainActor
class CameraViewModel: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var capturedImage: UIImage? = nil
    @Published var showDrawingCanvas = false
    @Published var permissionDenied = false
    /// Category inferred from the captured photo (nil until classified / if no match).
    @Published var detectedCategory: Category? = nil
    /// Multiple salient objects (only populated when the frame is ambiguous).
    @Published var detectedObjects: [DetectedObject] = []

    nonisolated(unsafe) let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false

    override init() {
        super.init()
        // Do NOT prompt for camera access on launch. The viewfinder stays black
        // until the user taps the camera to grant access. Only attach to the
        // camera here if access was already granted in a previous session.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            startSession()
        case .denied, .restricted:
            permissionDenied = true
        default:
            break   // .notDetermined → stay black, wait for the user to tap
        }
    }

    /// Call when the camera becomes active (sheet pulled down to expose viewfinder).
    /// Never prompts — that only happens on an explicit tap.
    func activateIfNeeded() {
        guard isAuthorized else { return }
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
    }

    func requestPermissionAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            isAuthorized = true
            startSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            permissionDenied = !granted
            if granted { startSession() }
        default:
            permissionDenied = true
        }
    }

    func startSession() {
        guard !configured else {
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
            }
            return
        }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { session.commitConfiguration(); return }

        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    func retake() {
        capturedImage = nil
        detectedCategory = nil
        detectedObjects = []
        showDrawingCanvas = false
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension CameraViewModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        Task { @MainActor in
            self.capturedImage = image
            self.showDrawingCanvas = true
            self.session.stopRunning()
        }
        // Identify immediately: whole-image category for the prefill, plus any
        // multiple salient objects for disambiguation tags.
        Task {
            let detected = try? await ImageClassifier.classify(image)
            await MainActor.run { self.detectedCategory = detected }
        }
        Task {
            let objects = await ImageClassifier.detectObjects(image)
            await MainActor.run { self.detectedObjects = objects }
        }
    }
}
