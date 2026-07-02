import Vision
import UIKit

/// A salient object found in a photo, with its inferred trade (home or auto).
/// `rect` is normalized (0–1) in Vision coords (origin bottom-left).
struct DetectedObject: Identifiable {
    let id = UUID()
    let rect: CGRect
    let match: TradeMatch
}

/// Photo → Category classifier.
///
/// Primary path: a cloud **vision LLM** (Hugging Face router, OpenAI-compatible
/// chat completions) for precise scene-aware classification. Falls back to
/// on-device Apple **Vision** when the network/token fails, so it always works.
enum ImageClassifier {

    enum ClassifyError: Error { case noImage, noMatch, unsure }

    /// On-device confidence floor for auto-suggesting a tag. Below this we treat the
    /// guess as unsure and don't preselect (tunable — raise if it over-preselects).
    private static let onDeviceMinConfidence: Float = 0.25

    // MARK: - Config

    /// HF token (free tier OK). Reads `HF_TOKEN` from Info.plist; when absent,
    /// classification falls back to on-device Apple Vision.
    private static let hfToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "HF_TOKEN") as? String) ?? ""

    private static let model = "Qwen/Qwen3-VL-8B-Instruct"

    /// Built from the live category lists so the options always match the app
    /// (no hand-maintained list to drift). The model first decides the vertical
    /// (vehicle vs home), then picks one category from that vertical.
    private static let prompt: String = {
        let home = Category.allCases.map(\.rawValue).joined(separator: ", ")
        let auto = autoCategoryItems.map(\.name).joined(separator: ", ")
        return "You route a repair request to the right contractor from one photo. "
            + "First decide whether the main subject is a VEHICLE (car, truck, or "
            + "motorcycle, or a part of one) or a HOME / property. Then choose exactly "
            + "ONE category:\n"
            + "- If it's a vehicle, choose from: \(auto).\n"
            + "- If it's a home/property, choose from: \(home).\n"
            + "Reply with only the chosen category name, exactly as written. "
            + "If the photo doesn't clearly show a single repairable subject, reply only: unsure."
    }()

    // MARK: - Public API

    /// Best-guess trade (home or auto) — cloud first, on-device Vision fallback.
    static func classify(_ image: UIImage) async throws -> TradeMatch {
        if let cloud = try? await classifyCloud(image) { return cloud }
        return try classifyOnDevice(image)
    }

    /// Classify only the region the user circled.
    static func classify(_ image: UIImage, regionInView rect: CGRect, viewSize: CGSize) async throws -> TradeMatch {
        let target = crop(image, viewRect: rect, viewSize: viewSize) ?? image
        return try await classify(target)
    }

    /// Whole-image classification for **auto-suggesting** a tag. Returns nil when
    /// the model isn't confident, so we don't preselect a wrong guess (e.g. a whole
    /// house read as "plumbing"). The cloud model may answer "unsure"; the on-device
    /// fallback is gated by a confidence floor. (The drawing path still uses the
    /// plain `classify`, which always returns a best guess — the user pointed at it.)
    static func classifyConfident(_ image: UIImage) async -> TradeMatch? {
        do { return try await classifyCloud(image) }
        catch ClassifyError.unsure { return nil }                          // model reachable but not sure
        catch { return try? classifyOnDevice(image, minConfidence: onDeviceMinConfidence) }
    }

    /// Best-effort car-vs-motorcycle guess (on-device), used to label the auto tags
    /// "Car repair" / "Moto repair". nil = neither clearly present.
    static func detectVehicleType(_ image: UIImage) -> VehicleFilter? {
        guard let cg = image.cgImage else { return nil }
        let req = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, orientation: cgOrientation(image.imageOrientation), options: [:]).perform([req])
        guard let obs = req.results else { return nil }
        var moto: Float = 0, car: Float = 0
        for o in obs where o.confidence > 0.05 {
            let l = o.identifier.lowercased()
            if ["motorcycle", "moped", "scooter", "motor scooter", "dirt bike"].contains(where: { l.contains($0) }) { moto += o.confidence }
            if ["car", "truck", "van", "automobile", "sedan", "suv", "pickup", "convertible", "sports car", "minivan"].contains(where: { l.contains($0) }) { car += o.confidence }
        }
        guard moto > 0 || car > 0 else { return nil }
        return moto > car ? .moto : .auto
    }

    /// Detect up to `max` salient objects and classify each (used to offer
    /// tappable tags when a photo has several things in frame). On-device Vision
    /// labels each region for speed; returns [] if fewer than 2 are found.
    static func detectObjects(_ image: UIImage, max: Int = 3) async -> [DetectedObject] {
        guard let cg = image.normalizedUp().cgImage else { return [] }
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        guard let obs = req.results?.first as? VNSaliencyImageObservation,
              let salient = obs.salientObjects else { return [] }

        let boxes = salient
            .sorted { $0.confidence > $1.confidence }
            .prefix(max)
            .map(\.boundingBox)
            .filter { $0.width > 0.08 && $0.height > 0.08 }   // drop slivers

        var out: [DetectedObject] = []
        for box in boxes {
            guard let region = cropNormalized(image, box),
                  let match = try? classifyOnDevice(region) else { continue }
            out.append(DetectedObject(rect: box, match: match))
        }
        // Only worth showing tags when there's genuine ambiguity.
        return out.count >= 2 ? dedupe(out) : []
    }

    // MARK: - Cloud (vision LLM)

    private static func classifyCloud(_ image: UIImage) async throws -> TradeMatch {
        guard !hfToken.isEmpty else { throw ClassifyError.noMatch }
        guard let jpeg = image.downscaled(maxDimension: 512).jpegData(compressionQuality: 0.7),
              let url = URL(string: "https://router.huggingface.co/v1/chat/completions")
        else { throw ClassifyError.noImage }

        let dataURI = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let payload: [String: Any] = [
            "model": model, "max_tokens": 20,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": dataURI]],
            ]]],
        ]
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw ClassifyError.noMatch }

        // Model was reachable — trust its verdict, including an explicit "unsure".
        if content.lowercased().contains("unsure") { throw ClassifyError.unsure }
        do { return try matchTrade(in: content) }
        catch { throw ClassifyError.unsure }   // reachable but unmappable → don't guess
    }

    /// Map a free-text classification reply to a home or auto category. Exact
    /// category names win; keyword hits are the fallback. Auto is checked first so
    /// vehicle-specific replies aren't swallowed by a looser home keyword.
    private static func matchTrade(in text: String) throws -> TradeMatch {
        let t = text.lowercased()
        if let auto = autoCategoryItems.first(where: { t.contains($0.name.lowercased()) }) { return .auto(auto) }
        if let home = Category.allCases.first(where: { t.contains($0.rawValue.lowercased()) }) { return .home(home) }
        if let auto = autoCategoryItems.first(where: { a in a.keywords.contains { t.contains($0) } }) { return .auto(auto) }
        let matched = Category.matching(query: text)
        if matched.count == 1 { return .home(matched[0]) }
        throw ClassifyError.noMatch
    }

    // MARK: - On-device Vision fallback

    private static func classifyOnDevice(_ image: UIImage, minConfidence: Float = 0) throws -> TradeMatch {
        guard let cg = image.cgImage else { throw ClassifyError.noImage }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: cgOrientation(image.imageOrientation), options: [:])
        try handler.perform([request])
        guard let observations = request.results else { throw ClassifyError.noMatch }

        var homeScores: [Category: Float] = [:]
        var autoScores: [Int: Float] = [:]   // index into autoCategoryItems
        for obs in observations where obs.confidence > 0.05 {
            let label = obs.identifier.lowercased().replacingOccurrences(of: "_", with: " ")
            for cat in Category.allCases where cat.keywords.contains(where: { label.contains($0) }) || label.contains(cat.rawValue.lowercased()) {
                homeScores[cat, default: 0] += obs.confidence
            }
            for (i, a) in autoCategoryItems.enumerated() where a.keywords.contains(where: { label.contains($0) }) {
                autoScores[i, default: 0] += obs.confidence
            }
        }

        let bestHome = homeScores.max(by: { $0.value < $1.value })
        let bestAuto = autoScores.max(by: { $0.value < $1.value })
        // Too weak to be trustworthy → unsure (callers that want a best guess pass
        // minConfidence: 0).
        if max(bestHome?.value ?? 0, bestAuto?.value ?? 0) < minConfidence {
            throw ClassifyError.unsure
        }
        switch (bestHome, bestAuto) {
        case let (h?, a?):   // tie favours auto — its keywords are vehicle-specific
            return a.value >= h.value ? .auto(autoCategoryItems[a.key]) : .home(h.key)
        case let (h?, nil):  return .home(h.key)
        case let (nil, a?):  return .auto(autoCategoryItems[a.key])
        default:             throw ClassifyError.noMatch
        }
    }

    // MARK: - Geometry

    /// Keep only the highest-area box per trade.
    private static func dedupe(_ objs: [DetectedObject]) -> [DetectedObject] {
        var byMatch: [TradeMatch: DetectedObject] = [:]
        for o in objs {
            if let e = byMatch[o.match], e.rect.width * e.rect.height >= o.rect.width * o.rect.height { continue }
            byMatch[o.match] = o
        }
        return Array(byMatch.values)
    }

    /// Crop a normalized Vision rect (origin bottom-left) from the image.
    private static func cropNormalized(_ image: UIImage, _ box: CGRect) -> UIImage? {
        let img = image.normalizedUp()
        guard let cg = img.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let r = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !r.isNull, r.width > 16, r.height > 16, let out = cg.cropping(to: r) else { return nil }
        return UIImage(cgImage: out)
    }

    /// Map a view-space rect (photo shown scaledToFill in `viewSize`) to a crop.
    private static func crop(_ image: UIImage, viewRect: CGRect, viewSize: CGSize) -> UIImage? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let img = image.normalizedUp()
        guard let cg = img.cgImage else { return nil }
        let isz = img.size
        let scale = max(viewSize.width / isz.width, viewSize.height / isz.height)
        let offsetX = (isz.width * scale - viewSize.width) / 2
        let offsetY = (isz.height * scale - viewSize.height) / 2
        let cropPts = CGRect(
            x: (viewRect.minX + offsetX) / scale, y: (viewRect.minY + offsetY) / scale,
            width: viewRect.width / scale, height: viewRect.height / scale)
        let px = img.scale
        var cropPx = CGRect(x: cropPts.minX * px, y: cropPts.minY * px, width: cropPts.width * px, height: cropPts.height * px)
        cropPx = cropPx.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !cropPx.isNull, cropPx.width > 16, cropPx.height > 16, let out = cg.cropping(to: cropPx) else { return nil }
        return UIImage(cgImage: out)
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up; case .down: return .down; case .left: return .left; case .right: return .right
        case .upMirrored: return .upMirrored; case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored; case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

private extension UIImage {
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let f = maxDimension / longest
        let newSize = CGSize(width: size.width * f, height: size.height * f)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
