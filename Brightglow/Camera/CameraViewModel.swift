import AVFoundation
import SwiftUI
import Combine

@MainActor
class CameraViewModel: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var capturedImage: UIImage? = nil
    @Published var showDrawingCanvas = false
    @Published var permissionDenied = false
    /// Trade inferred from the captured photo — home or auto. Only set when the
    /// classifier was CONFIDENT: this one preselects the input tag and routes an
    /// empty submit. (nil until classified, or when the guess was weak.)
    @Published var detectedMatch: TradeMatch? = nil
    /// Ordered guesses including weak ones (cloud verdict first, then the
    /// on-device read) — they lead the category carousel so every guess is one
    /// tap away, but are never preselected.
    @Published var suggestedMatches: [TradeMatch] = []
    /// Visible cost-relevant attributes from the photo (size, capacity,
    /// material — e.g. "40 gallon, tankless"), extracted alongside
    /// `detectedMatch`. Only set when the cloud classifier was confident.
    /// Used to narrow the price estimate, never the business search.
    @Published var detectedDetails: String? = nil
    /// Vehicle type inferred from the photo (car vs motorcycle) — labels the auto
    /// tags "Car repair" / "Moto repair". nil when no vehicle is recognised.
    @Published var detectedVehicle: VehicleFilter? = nil
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

    /// Stop the capture session when the viewfinder is no longer on screen (e.g.
    /// the user drilled into a category/gallery), so the camera powers down and
    /// the green in-use indicator goes away. The landing's `onAppear` resumes it.
    func deactivate() {
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
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

    /// Open a photo in the full-screen draw-over canvas and classify it — the
    /// same flow a camera capture takes, reused by the search bar's + upload so
    /// an uploaded picture behaves exactly like a shot one.
    func present(_ image: UIImage) {
        capturedImage = image
        showDrawingCanvas = true
        DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
        classify(image)
    }

    /// Identify immediately: whole-image category for the prefill, plus any
    /// multiple salient objects for disambiguation tags.
    private func classify(_ image: UIImage) {
        Task {
            // Confidence-gated: weak guesses only lead the carousel; a
            // certain cloud verdict stays in the background — it routes the
            // submit and stands in when the user provides no input, but is
            // never pre-selected in the UI (tag choice belongs to the user).
            let suggestions = await ImageClassifier.suggestTrades(image)
            await MainActor.run {
                self.suggestedMatches = suggestions.matches
                self.detectedMatch = suggestions.confident
                self.detectedDetails = suggestions.details
                // Cloud read wins — it's far more reliable than on-device Vision
                // at "this is a car / a motorcycle", which is what stops clarify
                // from asking the obvious. Fallback below fills in only if nil.
                if let vehicle = suggestions.vehicle { self.detectedVehicle = vehicle }
            }
        }
        Task {
            // Fast on-device first guess so the auto tags label car vs moto right
            // away; never clobbers the cloud read once it lands.
            let vehicle = ImageClassifier.detectVehicleType(image)
            await MainActor.run {
                if self.detectedVehicle == nil { self.detectedVehicle = vehicle }
            }
        }
        Task {
            let objects = await ImageClassifier.detectObjects(image)
            await MainActor.run { self.detectedObjects = objects }
        }
    }

    func retake() {
        capturedImage = nil
        detectedMatch = nil
        suggestedMatches = []
        detectedDetails = nil
        detectedVehicle = nil
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
        Task { @MainActor in self.present(image) }
    }
}
