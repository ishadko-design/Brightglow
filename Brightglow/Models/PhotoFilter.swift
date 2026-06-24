import Vision
import UIKit

/// Screens contractor gallery photos so the card stack shows actual work
/// examples (rooms, fixtures, installations) rather than staff portraits,
/// cars, logos/signage, flyers/menus, or blurry / low-resolution uploads.
/// Runs fully on-device with Apple Vision + Core Graphics.
enum PhotoFilter {

    // MARK: - Tunables

    /// Backstop minimum pixel dimension (shorter side) of the decoded screening
    /// thumbnail. Source resolution is already gated server-side via the photo
    /// metadata pre-filter (≥600px) in PlacesService.
    private static let minPixelDimension = 300
    /// Most good photos to keep per contractor for the card gallery.
    private static let maxKept = 6
    /// Width (px) of the rendition downloaded for screening. Big enough that blur
    /// is still detectable (small thumbnails smooth blur away), small enough that
    /// reviewing the whole 10-photo pool stays cheap. The full-size URL is what
    /// actually gets displayed.
    private static let screeningWidthPx = 800
    /// Laplacian variance below this reads as out-of-focus / blurry. Sharp photos
    /// score in the hundreds–thousands; soft / blurry ones below ~100.
    private static let minSharpness: Double = 110
    /// Reject when recognized text covers more than this fraction of the frame
    /// (menus, flyers, screenshots, heavily-watermarked images).
    private static let maxTextAreaFraction: Double = 0.05
    /// A single face covering more than this share of the frame = a portrait.
    private static let maxFaceAreaFraction: Double = 0.03
    /// Two or more faces = a group / staff photo, not the work.
    private static let maxFaces = 1
    /// Classification confidence at which a reject token vetoes the image.
    private static let rejectConfidence: Float = 0.35

    /// Vision classification tokens that mark a non-work image. Matched against
    /// the *tokens* of each identifier (split on `_`), never as substrings — so
    /// "carpet" is NOT rejected by "car", but "sports_car" is.
    private static let rejectTokens: Set<String> = [
        // people
        "people", "person", "portrait", "selfie", "crowd", "face",
        // vehicles
        "vehicle", "car", "automobile", "truck", "van", "motorcycle",
        "bicycle", "wheel", "tire", "traffic",
        // signage / documents
        "logo", "text", "document", "screenshot", "poster", "sign",
        "signage", "menu", "advertisement", "label",
        // food / animals (clearly off-topic for home work)
        "food", "meal", "drink", "fruit", "animal", "pet", "dog", "cat",
    ]

    // MARK: - Per-image decision

    /// True when the photo looks like a genuine, good-quality work example.
    static func isWorkExample(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }   // can't tell → keep

        // 1. Resolution backstop.
        if min(cg.width, cg.height) < minPixelDimension {
            log(cg, reject: "low-res \(cg.width)x\(cg.height)"); return false
        }

        // 2. Sharpness gate — reject blurry / out-of-focus images.
        let sharp = laplacianVariance(cg)
        if sharp < minSharpness {
            log(cg, reject: "blurry (sharpness \(Int(sharp)))"); return false
        }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let faceReq  = VNDetectFaceRectanglesRequest()
        let classReq = VNClassifyImageRequest()
        let textReq  = VNRecognizeTextRequest()
        textReq.recognitionLevel = .fast
        textReq.usesLanguageCorrection = false
        try? handler.perform([faceReq, classReq, textReq])

        // 3. Face / people gate — a prominent face, or more than one face, means
        //    the subject is people rather than the work.
        let faces = faceReq.results ?? []
        if faces.count > maxFaces {
            log(cg, reject: "\(faces.count) faces"); return false
        }
        if faces.contains(where: { $0.boundingBox.width * $0.boundingBox.height > maxFaceAreaFraction }) {
            log(cg, reject: "prominent face"); return false
        }

        // 4. Text gate — reject images dominated by text.
        if let lines = textReq.results {
            let textArea = lines.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
            if textArea > maxTextAreaFraction {
                log(cg, reject: "text-heavy (\(Int(textArea * 100))%)"); return false
            }
        }

        // 5. Scene gate — reject car / people / logo / food etc. classifications,
        //    matching whole identifier tokens (not substrings).
        if let obs = classReq.results {
            for o in obs where o.confidence > rejectConfidence {
                let tokens = o.identifier.lowercased().split(whereSeparator: { !$0.isLetter })
                if tokens.contains(where: { rejectTokens.contains(String($0)) }) {
                    log(cg, reject: "scene: \(o.identifier) \(Int(o.confidence * 100))%"); return false
                }
            }
        }
        return true
    }

    // MARK: - Sharpness (variance of the Laplacian)

    /// Downscales to grayscale (aspect-preserving) and returns the variance of
    /// the Laplacian — a standard focus metric. Higher = sharper.
    private static func laplacianVariance(_ cg: CGImage) -> Double {
        let maxSide = 384
        let scale = Double(maxSide) / Double(max(cg.width, cg.height))
        let w = max(8, Int(Double(cg.width) * scale))
        let h = max(8, Int(Double(cg.height) * scale))
        var gray = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &gray, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return .greatestFiniteMagnitude }   // can't measure → keep
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var values = [Double]()
        values.reserveCapacity((w - 2) * (h - 2))
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = Int(gray[i - 1]) + Int(gray[i + 1])
                        + Int(gray[i - w]) + Int(gray[i + w])
                        - 4 * Int(gray[i])
                values.append(Double(lap))
            }
        }
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance
    }

    // MARK: - Batch screening

    /// Screen a candidate pool of photo URLs, returning up to `maxKept` genuine
    /// work examples (full-size display URLs). Each candidate is analysed on a
    /// medium screening rendition so blur stays detectable while the pool review
    /// stays cheap. Never returns empty — falls back to the original list.
    static func screen(_ urls: [String]) async -> [String] {
        var kept: [String] = []
        for displayURL in urls {
            if kept.count >= maxKept { break }
            let scrURLStr = screeningURL(from: displayURL)
            guard let url = URL(string: scrURLStr) else { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = UIImage(data: data) {
                if isWorkExample(img) { kept.append(displayURL) }   // display full-size
            } else {
                kept.append(displayURL)
            }
        }
        return kept.isEmpty ? Array(urls.prefix(maxKept)) : kept
    }

    /// Derives the screening rendition URL from a full-size display URL by
    /// shrinking the Places `maxWidthPx` parameter.
    private static func screeningURL(from displayURL: String) -> String {
        guard let range = displayURL.range(of: #"maxWidthPx=\d+"#, options: .regularExpression)
        else { return displayURL }
        return displayURL.replacingCharacters(in: range, with: "maxWidthPx=\(screeningWidthPx)")
    }

    // MARK: - Debug

    /// Logs why a photo was rejected (DEBUG builds only) for threshold tuning.
    private static func log(_ cg: CGImage, reject reason: String) {
        #if DEBUG
        print("📷 PhotoFilter reject [\(cg.width)x\(cg.height)] — \(reason)")
        #endif
    }
}
