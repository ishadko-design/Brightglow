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
    /// A concise, ready-to-show phrase describing the subject and its problem
    /// ("Blue Chevrolet Volt with large dents on the front door") — used to
    /// auto-fill the capture input so the user sees what we understood. nil until
    /// classified, or when the model couldn't describe it.
    @Published var detectedDescription: String? = nil
    /// Multiple salient objects (only populated when the frame is ambiguous).
    @Published var detectedObjects: [DetectedObject] = []
    /// Bumped every time a classification COMPLETES — whole-image or a circled
    /// region. Lets the draw UI react to a re-read even when the resulting text is
    /// identical to the last (a plain `detectedDescription` change wouldn't fire),
    /// so circling always shows fresh feedback. See DrawModeView's draw handling.
    @Published var classifyGeneration = 0

    /// Live pinch-to-zoom factor, 1× = no zoom. Published so the preview's
    /// gesture can pick up where the last pinch left off.
    @Published private(set) var zoomFactor: CGFloat = 1

    nonisolated(unsafe) let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    /// The active capture device — held so pinch can drive its zoom.
    private var device: AVCaptureDevice?
    /// The device zoom factor that corresponds to the standard "1×" wide framing
    /// the viewfinder opens at. On a phone with an ultra-wide lens the zoom scale
    /// is anchored to the ULTRA-WIDE (factor 1.0 ≈ the 0.5× wide view), so the
    /// normal 1× is the switch-over factor to the main lens (typically 2.0);
    /// pinching below it reaches the ultra-wide for a wider shot. 1.0 on phones
    /// that only have the wide lens, where zoom-out isn't possible.
    private var baseZoom: CGFloat = 1
    /// Tele ceiling for pinch, expressed as a multiple of the standard 1× framing
    /// (`baseZoom`). The hardware allows far more, but past ~8× a phone camera is
    /// upscaling mush — and a photo of a task is what the classifier has to read.
    private let maxZoom: CGFloat = 8

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
            let device = Self.bestBackDevice(),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { session.commitConfiguration(); return }

        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        // Opt into the computational-photography quality that IS available to
        // third-party apps (Deep Fusion / Smart HDR) and capture at the sensor's
        // full resolution — the default is a flatter, lower-res image. (Night mode
        // stays Apple-only, so very dark scenes still lag the native camera.)
        output.maxPhotoQualityPrioritization = .quality
        if let maxDim = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            output.maxPhotoDimensions = maxDim
        }
        session.commitConfiguration()
        self.device = device
        // Anchor "1×" to the main wide lens (the switch-over factor on a device
        // that also has an ultra-wide), so the viewfinder opens at the same
        // framing as before while a pinch-out can now dip into the ultra-wide.
        baseZoom = device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat($0.doubleValue) } ?? 1
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = baseZoom
            device.unlockForConfiguration()
        }
        zoomFactor = device.videoZoomFactor

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        // Max quality (engages Deep Fusion/Smart HDR when the scene allows) and
        // full-resolution capture, matching what the output was configured for.
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        output.capturePhoto(with: settings, delegate: self)
    }

    /// The back camera to open. Prefer a virtual device that INCLUDES the
    /// ultra-wide lens, so the user can zoom OUT past the normal wide framing to
    /// fit a whole subject in one shot — a full fence, a wall of windows, a whole
    /// car — instead of being stuck shooting up close. Falls back to the plain
    /// wide lens on phones with no ultra-wide (SE / older), where zoom-out simply
    /// isn't available and the viewfinder behaves exactly as before.
    private static func bestBackDevice() -> AVCaptureDevice? {
        for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera] {
            if let d = AVCaptureDevice.default(type, for: .video, position: .back) { return d }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Set the pinch zoom, clamped to what the device actually supports. The floor
    /// is the device minimum (1.0 on an ultra-wide device — the ~0.5× wide view —
    /// so the user can zoom OUT below the standard framing); the ceiling is
    /// `maxZoom`× the standard 1× framing. Applied straight to the device, so the
    /// preview and the photo it captures zoom together — no cropping on our side.
    func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        let ceiling = min(baseZoom * maxZoom, device.maxAvailableVideoZoomFactor)
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), ceiling)
        guard let _ = try? device.lockForConfiguration() else { return }
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        zoomFactor = clamped
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
                self.detectedDescription = suggestions.description
                // `suggestions.vehicle` is already gated on an auto subject (it's
                // nil for a home photo even if a car is visible in the background),
                // so trusting it directly can't flip a home request to the vehicle
                // path. It combines the cloud car-vs-moto read with an on-device
                // fallback — no separate whole-image vehicle guess is needed here,
                // and adding one back would reintroduce the home-photo misroute.
                self.detectedVehicle = suggestions.vehicle
                self.classifyGeneration &+= 1
            }
        }
        Task {
            let objects = await ImageClassifier.detectObjects(image)
            await MainActor.run { self.detectedObjects = objects }
        }
    }

    /// Re-classify just the region the user circled and replace the detected
    /// verdict with it. Drawing over an area disambiguates a busy frame — circling
    /// the cabinets in a shot the whole-frame read called "hardwood floor" should
    /// flip the auto-description (and the routing) to the cabinets. `rect` is in
    /// the draw canvas's view space, `viewSize` its size.
    ///
    /// `annotated` is the photo WITH the user's loop drawn on it. We classify that
    /// (not the bare capture) so the model can SEE what was circled: a loop-less
    /// crop is just a box of pixels the model fills with its own prior (it kept
    /// picking a door over a circled beam/ramp/fence, reported 2026-09-06).
    func reclassifyRegion(_ rect: CGRect, viewSize: CGSize, annotated: UIImage) {
        Task {
            let s = await ImageClassifier.suggestTrades(annotated, regionInView: rect, viewSize: viewSize)
            await MainActor.run {
                // Only adopt a region read that actually resolved to something — a
                // blank/too-small crop must not wipe the useful whole-frame guess.
                guard s.description != nil || s.confident != nil || !s.matches.isEmpty else { return }
                self.suggestedMatches = s.matches
                self.detectedMatch = s.confident
                self.detectedDetails = s.details
                self.detectedDescription = s.description
                self.detectedVehicle = s.vehicle
                self.classifyGeneration &+= 1
            }
        }
    }

    func retake() {
        capturedImage = nil
        detectedMatch = nil
        suggestedMatches = []
        detectedDetails = nil
        detectedDescription = nil
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
