import Vision
import UIKit

/// A salient object found in a photo, with its inferred category.
/// `rect` is normalized (0–1) in Vision coords (origin bottom-left).
struct DetectedObject: Identifiable {
    let id = UUID()
    let rect: CGRect
    let category: Category
}

/// Photo → Category classifier.
///
/// Primary path: a cloud **vision LLM** (Hugging Face router, OpenAI-compatible
/// chat completions) for precise scene-aware classification. Falls back to
/// on-device Apple **Vision** when the network/token fails, so it always works.
enum ImageClassifier {

    enum ClassifyError: Error { case noImage, noMatch }

    // MARK: - Config

    /// HF token (free tier OK). Reads `HF_TOKEN` from Info.plist; when absent,
    /// classification falls back to on-device Apple Vision.
    private static let hfToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "HF_TOKEN") as? String) ?? ""

    private static let model = "Qwen/Qwen3-VL-8B-Instruct"

    private static let prompt =
        "You route home-repair requests to the right contractor. Looking at the main "
        + "subject of this photo, choose exactly ONE trade from this list: "
        + "Plumbing, Electrical, HVAC, Painting, Carpentry, Roofing, Flooring, Windows & Doors. "
        + "Reply with only the category name, exactly as written."

    // MARK: - Public API

    /// Best-guess category — cloud first, on-device Vision fallback.
    static func classify(_ image: UIImage) async throws -> Category {
        if let cloud = try? await classifyCloud(image) { return cloud }
        return try classifyOnDevice(image)
    }

    /// Classify only the region the user circled.
    static func classify(_ image: UIImage, regionInView rect: CGRect, viewSize: CGSize) async throws -> Category {
        let target = crop(image, viewRect: rect, viewSize: viewSize) ?? image
        return try await classify(target)
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
                  let cat = try? classifyOnDevice(region) else { continue }
            out.append(DetectedObject(rect: box, category: cat))
        }
        // Only worth showing tags when there's genuine ambiguity.
        return out.count >= 2 ? dedupe(out) : []
    }

    // MARK: - Cloud (vision LLM)

    private static func classifyCloud(_ image: UIImage) async throws -> Category {
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

        let text = content.lowercased()
        if let exact = Category.allCases.first(where: { text.contains($0.rawValue.lowercased()) }) { return exact }
        let matched = Category.matching(query: content)
        if matched.count == 1 { return matched[0] }
        throw ClassifyError.noMatch
    }

    // MARK: - On-device Vision fallback

    private static func classifyOnDevice(_ image: UIImage) throws -> Category {
        guard let cg = image.cgImage else { throw ClassifyError.noImage }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: cgOrientation(image.imageOrientation), options: [:])
        try handler.perform([request])
        guard let observations = request.results else { throw ClassifyError.noMatch }

        var scores: [Category: Float] = [:]
        for obs in observations where obs.confidence > 0.05 {
            let label = obs.identifier.lowercased().replacingOccurrences(of: "_", with: " ")
            for cat in Category.allCases where cat.keywords.contains(where: { label.contains($0) }) || label.contains(cat.rawValue.lowercased()) {
                scores[cat, default: 0] += obs.confidence
            }
        }
        guard let best = scores.max(by: { $0.value < $1.value })?.key else { throw ClassifyError.noMatch }
        return best
    }

    // MARK: - Geometry

    /// Keep only the highest-area box per category.
    private static func dedupe(_ objs: [DetectedObject]) -> [DetectedObject] {
        var byCat: [Category: DetectedObject] = [:]
        for o in objs {
            if let e = byCat[o.category], e.rect.width * e.rect.height >= o.rect.width * o.rect.height { continue }
            byCat[o.category] = o
        }
        return Array(byCat.values)
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
