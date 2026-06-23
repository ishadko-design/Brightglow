import Vision
import UIKit

/// Screens contractor gallery photos so the card stack shows actual work
/// examples (rooms, fixtures, installations) rather than staff portraits or
/// company logos / signage. Runs fully on-device with Apple Vision.
enum PhotoFilter {

    /// Scene labels that indicate a non-work image (a person or a logo/sign).
    private static let rejectLabels: Set<String> = [
        "people", "person", "face", "portrait", "selfie",
        "logo", "text", "document", "screenshot", "poster",
        "sign", "signage", "menu", "advertisement", "business_card",
    ]

    /// True when the photo looks like a genuine work example.
    static func isWorkExample(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }   // can't tell → keep
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        let faceReq  = VNDetectFaceRectanglesRequest()
        let classReq = VNClassifyImageRequest()
        try? handler.perform([faceReq, classReq])

        // Reject portraits — a face covering a meaningful share of the frame
        // means the subject is a person, not the work.
        if let faces = faceReq.results,
           faces.contains(where: { $0.boundingBox.width * $0.boundingBox.height > 0.05 }) {
            return false
        }

        // Reject logo / text / people-dominant scenes.
        if let obs = classReq.results {
            let hits = obs
                .filter { $0.confidence > 0.3 }
                .map { $0.identifier.lowercased() }
            if hits.contains(where: { id in rejectLabels.contains(where: { id.contains($0) }) }) {
                return false
            }
        }
        return true
    }

    /// Download + screen a list of photo URLs, returning only the work examples.
    /// Never returns empty — falls back to the original list so a card is never
    /// blank — and keeps photos whose download fails (benefit of the doubt).
    static func screen(_ urls: [String]) async -> [String] {
        var kept: [String] = []
        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = UIImage(data: data) {
                if isWorkExample(img) { kept.append(urlStr) }
            } else {
                kept.append(urlStr)
            }
        }
        return kept.isEmpty ? urls : kept
    }
}
