import Vision
import UIKit

/// A kept work photo plus its Vision scene labels. Carrying the labels (through
/// the on-device store and the shared verdict cache) lets the app order photos by
/// relevance to the user's query at display time — no re-download, no re-classify.
struct ScreenedPhoto: Codable, Hashable {
    let url: String
    let labels: [String]
}

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
    /// Keep every work photo a business has so the user can page through them all.
    /// Bounded by the Google Places API, which returns at most 10 photos per place.
    private static let maxKept = 10
    /// Laplacian variance below this reads as out-of-focus / blurry. Sharp photos
    /// score in the hundreds–thousands; soft / blurry ones below ~100.
    private static let minSharpness: Double = 110
    /// Reject when recognized text covers more than this fraction of the frame
    /// (menus, flyers, screenshots, heavily-watermarked images).
    private static let maxTextAreaFraction: Double = 0.05
    /// A single face covering more than this share of the frame = a posed
    /// portrait / selfie (the person, not their work, is the subject).
    private static let maxFaceAreaFraction: Double = 0.06
    /// Two or more faces = a group / staff photo, not the work.
    private static let maxFaces = 1
    /// Two or more detected human bodies = a group / staff / crowd photo. Body
    /// detection catches standing or distant people that face detection misses.
    /// A *single* person is allowed — that's typically someone doing the work.
    private static let maxHumans = 1
    /// Minimum confidence for a human-body detection to count.
    private static let humanConfidence: Float = 0.5
    /// Classification confidence at which a reject token vetoes the image.
    private static let rejectConfidence: Float = 0.35

    /// Vision classification tokens that mark a non-work image. Matched against
    /// the *tokens* of each identifier (split on `_`), never as substrings — so
    /// "carpet" is NOT rejected by "car", but "sports_car" is.
    private static let rejectTokens: Set<String> = [
        // people
        "people", "person", "portrait", "selfie", "crowd", "face",
        // signage / documents
        "logo", "text", "document", "screenshot", "poster", "sign",
        "signage", "menu", "advertisement", "label",
        // food / animals (clearly off-topic)
        "food", "meal", "drink", "fruit", "animal", "pet", "dog", "cat",
    ]

    /// Vehicle tokens — rejected for HOME trades (a car isn't the work), but kept
    /// for AUTO & moto services where the vehicle *is* the work example.
    private static let vehicleTokens: Set<String> = [
        "vehicle", "car", "automobile", "truck", "van", "motorcycle",
        "bicycle", "wheel", "tire", "traffic",
    ]

    // MARK: - Per-image decision

    /// Outcome of screening one photo: whether to keep it, and whether its subject
    /// is a vehicle (used to rank vehicle/work shots first for auto & moto).
    struct Decision { let keep: Bool; let isVehicle: Bool; let labels: [String] }
    private static let reject = Decision(keep: false, isVehicle: false, labels: [])

    /// True when the photo looks like a genuine, good-quality work example.
    /// `allowVehicles` keeps car/truck/motorcycle photos (auto & moto work).
    static func isWorkExample(_ image: UIImage, allowVehicles: Bool = false) -> Bool {
        evaluate(image, allowVehicles: allowVehicles).keep
    }

    /// Full screening decision for one photo.
    static func evaluate(_ image: UIImage, allowVehicles: Bool = false) -> Decision {
        let rejects = allowVehicles ? rejectTokens : rejectTokens.union(vehicleTokens)
        guard let cg = image.cgImage else { return Decision(keep: true, isVehicle: false, labels: []) }   // can't tell → keep

        // 1. Resolution backstop.
        if min(cg.width, cg.height) < minPixelDimension {
            log(cg, reject: "low-res \(cg.width)x\(cg.height)"); return reject
        }

        // 2. Sharpness gate — reject blurry / out-of-focus images.
        let sharp = laplacianVariance(cg)
        if sharp < minSharpness {
            log(cg, reject: "blurry (sharpness \(Int(sharp)))"); return reject
        }

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let faceReq  = VNDetectFaceRectanglesRequest()
        let humanReq = VNDetectHumanRectanglesRequest()
        if #available(iOS 15.0, *) { humanReq.upperBodyOnly = false }
        let classReq = VNClassifyImageRequest()
        let textReq  = VNRecognizeTextRequest()
        textReq.recognitionLevel = .fast
        textReq.usesLanguageCorrection = false
        // Perform each request independently: if one type is unsupported on the
        // current device/simulator it throws, and a single batched `perform`
        // would then void *every* gate (letting all photos through).
        try? handler.perform([faceReq])
        try? handler.perform([humanReq])
        try? handler.perform([classReq])
        try? handler.perform([textReq])

        // 3. Face / people gate — a prominent face, or more than one face, means
        //    the subject is people rather than the work.
        let faces = faceReq.results ?? []
        if faces.count > maxFaces {
            log(cg, reject: "\(faces.count) faces"); return reject
        }
        if faces.contains(where: { $0.boundingBox.width * $0.boundingBox.height > maxFaceAreaFraction }) {
            log(cg, reject: "prominent face"); return reject
        }

        // 3b. Human-body gate — catches standing / distant / posed people that
        //     face detection misses (staff line-ups, group/office shots). Only a
        //     *group* (2+ bodies) is rejected; a single person is kept, since
        //     that's usually a worker doing the job — and a posed solo portrait
        //     is already caught by the prominent-face check above.
        let humans = (humanReq.results ?? []).filter { $0.confidence >= humanConfidence }
        if humans.count > maxHumans {
            log(cg, reject: "\(humans.count) people"); return reject
        }

        // 4. Text gate — reject images dominated by text.
        if let lines = textReq.results {
            let textArea = lines.reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
            if textArea > maxTextAreaFraction {
                log(cg, reject: "text-heavy (\(Int(textArea * 100))%)"); return reject
            }
        }

        // 5. Scene gate — reject people / logo / food etc. (and vehicles unless
        //    allowed). Also note whether the subject IS a vehicle, so auto & moto
        //    results can rank those work shots first.
        var isVehicle = false
        var labels: [String] = []
        if let obs = classReq.results {
            for o in obs where o.confidence > rejectConfidence {
                let tokens = o.identifier.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                if tokens.contains(where: { vehicleTokens.contains($0) }) { isVehicle = true }
                if tokens.contains(where: { rejects.contains($0) }) {
                    log(cg, reject: "scene: \(o.identifier) \(Int(o.confidence * 100))%"); return reject
                }
            }
            // Scene labels (kitchen, bathroom, roof…) so the app can order photos by
            // relevance to the user's query later, without re-classifying.
            labels = Array(Set(obs
                .filter { $0.confidence > 0.10 }
                .flatMap { $0.identifier.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) }))
        }
        return Decision(keep: true, isVehicle: isVehicle, labels: labels)
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
    /// stays cheap.
    ///
    /// May return an empty array: when a contractor's entire pool is non-work
    /// imagery (branded vehicles, staff portraits, flyers/menus, logos) every
    /// candidate is rejected, and we deliberately return nothing rather than
    /// re-adding the junk — the gallery then shows a placeholder. Only a *failed
    /// download* (which we can't judge) is kept, so transient network errors
    /// don't blank an otherwise-good gallery.
    /// - Parameters:
    ///   - limit: max photos to keep (the list strip needs only a few; the
    ///     full-screen gallery wants all available).
    ///   - scanLimit: max photos to download/evaluate. Caps Places Photo requests
    ///     for the cheap list pass; the gallery scans the whole pool to rank well.
    /// Screening downloads the small **list** rendition, so a kept strip photo is
    /// already cached — no second request for the thumbnail.
    static func screen(_ urls: [String], allowVehicles: Bool = false,
                       limit: Int = maxKept, scanLimit: Int = .max) async -> [ScreenedPhoto] {
        // Two buckets so auto & moto results lead with the actual vehicle/work
        // shots; non-vehicle keepers (and unjudged) follow in original order.
        var vehicle: [ScreenedPhoto] = []
        var other: [ScreenedPhoto] = []
        var scanned = 0
        for displayURL in urls {
            if scanned >= scanLimit { break }
            scanned += 1
            let screenURL = PlacesService.photoURL(displayURL, width: PlacesService.listPhotoWidth)
            guard let url = URL(string: screenURL) else { continue }
            // Use the shared authenticated loader: Places' bundle-restricted API
            // key 403s a plain URLSession request, so a raw fetch here would fail
            // every time and silently keep all photos unscreened.
            if let img = await ImageCache.download(url) {
                let decision = await evaluateOffPool(img, allowVehicles: allowVehicles)
                guard decision.keep else { continue }
                let photo = ScreenedPhoto(url: displayURL, labels: decision.labels)
                if allowVehicles && decision.isVehicle { vehicle.append(photo) }
                else { other.append(photo) }
            } else {
                other.append(ScreenedPhoto(url: displayURL, labels: []))   // couldn't fetch to judge → keep
            }
        }
        return Array((vehicle + other).prefix(limit))   // display full-size, work shots first
    }

    /// Order kept photos so those whose scene labels match the query lead (stable
    /// for ties); returns display URLs. No meaningful query terms → original order.
    /// This is what surfaces the kitchen shot first for a "kitchen remodel" search,
    /// working off stored labels so it needs no re-download or re-classification.
    static func order(_ photos: [ScreenedPhoto], query: String) -> [String] {
        let terms = query.lowercased()
            .split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 3 }
        guard !terms.isEmpty else { return photos.map(\.url) }
        return photos.enumerated()
            .sorted { a, b in
                let sa = matchScore(a.element.labels, terms)
                let sb = matchScore(b.element.labels, terms)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map { $0.element.url }
    }

    private static func matchScore(_ labels: [String], _ terms: [String]) -> Int {
        terms.reduce(0) { acc, t in
            acc + (labels.contains { $0.contains(t) || t.contains($0) } ? 1 : 0)
        }
    }

    /// Vision screening is heavy synchronous CPU work (four ML requests per photo).
    /// Running it inline leaves it on Swift's cooperative thread pool — the small
    /// pool every `async` task shares — so screening many businesses at once
    /// saturates it and starves everything else: image downloads stall and a
    /// pushed screen (the gallery) can't get a thread to load, so it looks like it
    /// won't open. Hop to a dedicated GCD queue so the cooperative pool stays free.
    private static let visionQueue = DispatchQueue(
        label: "photofilter.vision", qos: .userInitiated, attributes: .concurrent)

    private static func evaluateOffPool(_ image: UIImage, allowVehicles: Bool) async -> Decision {
        await withCheckedContinuation { cont in
            visionQueue.async { cont.resume(returning: evaluate(image, allowVehicles: allowVehicles)) }
        }
    }

    // MARK: - Debug

    /// Logs why a photo was rejected (DEBUG builds only) for threshold tuning.
    private static func log(_ cg: CGImage, reject reason: String) {
        #if DEBUG
        print("📷 PhotoFilter reject [\(cg.width)x\(cg.height)] — \(reason)")
        #endif
    }
}
