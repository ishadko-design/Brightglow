import Vision
import UIKit

/// A kept work photo plus its Vision scene labels. Carrying the labels (through
/// the on-device store and the shared verdict cache) lets the app order photos by
/// relevance to the user's query at display time — no re-download, no re-classify.
struct ScreenedPhoto: Codable, Hashable {
    let url: String
    let labels: [String]
    /// 64-bit perceptual hash (pHash) of the screening rendition. Used to drop
    /// near-duplicate shots ACROSS sources at display time — the Vision-feature
    /// dedup inside `screen()` only sees a single call's pool, so a website photo
    /// that duplicates a Google one (or a cached-then-re-added shot) slipped
    /// through before. Optional: photos from a shared verdict or an older cache
    /// carry none, and dedup falls back to URL equality for those.
    var phash: UInt64?

    init(url: String, labels: [String], phash: UInt64? = nil) {
        self.url = url
        self.labels = labels
        self.phash = phash
    }
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
    /// `nonisolated`: it's a default argument, evaluated in the caller's context —
    /// the project's MainActor default isolation flags that without this.
    private nonisolated static let maxKept = 10
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
        // illustrations / clip-art / cartoons — a drawn mascot is not a work photo
        // (the pixel-based `isFlatGraphic` gate is the primary catch; these tokens
        // back it up when Vision confidently recognises the drawing).
        "illustration", "drawing", "sketch", "cartoon", "comic", "doodle",
        "caricature", "animation", "graphic",
        // food / animals (clearly off-topic)
        "food", "meal", "drink", "fruit", "animal", "pet", "dog", "cat",
    ]

    /// Vehicle tokens — rejected for HOME trades (a car isn't the work), but kept
    /// for AUTO & moto services where the vehicle *is* the work example.
    private static let vehicleTokens: Set<String> = [
        "vehicle", "car", "automobile", "truck", "van", "motorcycle",
        "bicycle", "wheel", "tire", "traffic",
    ]

    /// Motorcycle-family scene tokens (Vision splits "motor_scooter" → "scooter").
    private static let motoTokens: Set<String> = [
        "motorcycle", "motorbike", "moped", "scooter",
    ]
    /// Car/truck-family scene tokens — the vehicles a Moto search must NOT show.
    /// (Component words after the classifier splits on non-letters: "sports_car"
    /// → "car", "minivan" stays whole, etc.)
    private static let carTokens: Set<String> = [
        "car", "automobile", "truck", "van", "minivan", "pickup", "suv",
        "sedan", "coupe", "convertible", "jeep", "limousine", "cab", "wagon", "bus",
    ]

    /// Keep only photos matching the selected vehicle type, dropping the OTHER
    /// vehicle (a car on a Moto search, a bike on a car search) — even for a shop
    /// that does both. Non-vehicle work shots (a paint booth, a tool) are always
    /// kept; only a clearly off-type vehicle is dropped. `vehicle` nil (home, or no
    /// toggle) filters nothing. Reads the tokens already stored on each photo, so
    /// it needs no re-classification and is independent of the screening cache.
    static func matchingVehicle(_ photos: [ScreenedPhoto], _ vehicle: VehicleFilter?) -> [ScreenedPhoto] {
        guard let vehicle else { return photos }
        return photos.filter { photo in
            let s = Set(photo.labels)
            let isMoto = !s.isDisjoint(with: motoTokens)
            let isCar  = !s.isDisjoint(with: carTokens)
            switch vehicle {
            case .moto: return !(isCar && !isMoto)   // drop cars that aren't also bikes
            case .auto: return !(isMoto && !isCar)   // drop bikes that aren't also cars
            }
        }
    }

    // MARK: - Per-image decision

    /// Outcome of screening one photo: whether to keep it, whether its subject
    /// is a vehicle (used to rank vehicle/work shots first for auto & moto), and
    /// its Vision feature print (a perceptual fingerprint used to drop
    /// near-duplicate shots so the mosaic/strip show distinct photos).
    struct Decision {
        let keep: Bool
        let isVehicle: Bool
        let labels: [String]
        var featurePrint: VNFeaturePrintObservation? = nil
        /// Perceptual hash carried onto the kept `ScreenedPhoto` for cross-source
        /// dedup (see `ScreenedPhoto.phash` / `deduped`).
        var phash: UInt64? = nil
    }
    private static let reject = Decision(keep: false, isVehicle: false, labels: [])

    /// Feature-print distance below which two photos read as the same shot. Google
    /// Places pools routinely include near-identical images (same job, seconds
    /// apart); smaller distance = more alike. Tuned to catch obvious dupes without
    /// merging genuinely different angles of the same job.
    private static let duplicateDistance: Float = 0.32

    /// Hamming distance (out of 64 bits) below which two pHashes read as the same
    /// shot. Used for cross-source dedup, where the Vision feature print isn't
    /// available (a cached/website photo). Conservative — catches re-uploads and
    /// mild re-crops/zooms without merging genuinely different angles.
    private static let phashThreshold = 8

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

        // 2b. Illustration / clip-art gate — a drawn mascot or vector graphic is
        //     sharp, high-res and trips no face/text/scene gate, so it used to pass
        //     as a "work photo". Flat art has few distinct colours and large solid
        //     fills, which a real photograph never does. Cheap pixel stats, run
        //     before the ML requests so obvious graphics skip them entirely.
        if isFlatGraphic(cg) {
            return reject   // isFlatGraphic already logs the reason
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
        return Decision(keep: true, isVehicle: isVehicle, labels: labels,
                        featurePrint: featurePrint(cg), phash: perceptualHash(cg))
    }

    /// Perceptual fingerprint of an image (nil if Vision can't produce one),
    /// compared via `computeDistance` to spot near-duplicate photos.
    private static func featurePrint(_ cg: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        return req.results?.first as? VNFeaturePrintObservation
    }

    /// True when `fp` is within `duplicateDistance` of any already-kept print.
    private static func isNearDuplicate(_ fp: VNFeaturePrintObservation,
                                        of kept: [VNFeaturePrintObservation]) -> Bool {
        for other in kept {
            var distance = Float.greatestFiniteMagnitude
            if (try? fp.computeDistance(&distance, to: other)) != nil, distance < duplicateDistance {
                return true
            }
        }
        return false
    }

    // MARK: - Flat-graphic (illustration) detection

    /// True when the image reads as a flat illustration / clip-art / cartoon rather
    /// than a photograph: very few distinct colours, large solid-fill regions, and a
    /// dominant flat background. A real photo — even of a plain wall — carries
    /// lighting gradients and sensor/JPEG texture that keep its colour count high
    /// and its flat-run fraction low, so it clears every threshold. Nearest-neighbour
    /// downscale (no interpolation) so solid fills stay pure and the signal survives.
    private static func isFlatGraphic(_ cg: CGImage) -> Bool {
        let n = 96
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: n * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }   // can't measure → treat as photo (keep)
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))

        // Quantise to 4 bits/channel; count distinct colours, the dominant share,
        // and the fraction of pixels sitting inside a solid fill (equal to the
        // pixel to their right and below).
        @inline(__always) func quant(_ i: Int) -> UInt16 {
            (UInt16(px[i] >> 4) << 8) | (UInt16(px[i + 1] >> 4) << 4) | UInt16(px[i + 2] >> 4)
        }
        var counts = [UInt16: Int]()
        var flatRuns = 0
        for y in 0..<n {
            for x in 0..<n {
                let i = (y * n + x) * 4
                let c = quant(i)
                counts[c, default: 0] += 1
                if x + 1 < n, y + 1 < n, quant(i + 4) == c, quant(i + n * 4) == c {
                    flatRuns += 1
                }
            }
        }
        let total = n * n
        let distinctRatio = Double(counts.count) / Double(total)
        let dominant = Double(counts.values.max() ?? 0) / Double(total)
        let flatRatio = Double(flatRuns) / Double((n - 1) * (n - 1))

        let flat = distinctRatio < 0.12 && flatRatio > 0.45 && dominant > 0.15
        if flat {
            log(cg, reject: "flat graphic (colors \(counts.count), flat \(Int(flatRatio * 100))%, dom \(Int(dominant * 100))%)")
        }
        return flat
    }

    // MARK: - Perceptual hash (pHash) & cross-source dedup

    /// Precomputed DCT basis: `dctCos[u][x] = cos((2x+1)·u·π / 2N)` for N=32.
    /// Lifts the cosines out of the per-image hot loop.
    private static let dctCos: [[Double]] = {
        let n = 32
        let size = 8
        var table = [[Double]](repeating: [Double](repeating: 0, count: n), count: size)
        for u in 0..<size {
            for x in 0..<n {
                let angle = (Double(2 * x + 1) * Double(u) * Double.pi) / Double(2 * n)
                table[u][x] = cos(angle)
            }
        }
        return table
    }()

    /// 64-bit DCT-based perceptual hash. Downscales to 32×32 grayscale, takes the
    /// low-frequency 8×8 DCT block, and sets each bit where the coefficient exceeds
    /// the block's median (excluding DC). Robust to scaling, re-compression and mild
    /// re-crops — so a Google shot and its website re-upload hash within a few bits.
    private static func perceptualHash(_ cg: CGImage) -> UInt64? {
        let n = 32, size = 8
        var bytes = [UInt8](repeating: 0, count: n * n)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &bytes, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: n, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))

        var coeffs = [Double](repeating: 0, count: size * size)
        for u in 0..<size {
            let cu = dctCos[u]
            for v in 0..<size {
                let cv = dctCos[v]
                var sum = 0.0
                for x in 0..<n {
                    let cux = cu[x]
                    let row = x * n
                    for y in 0..<n {
                        sum += Double(bytes[row + y]) * cux * cv[y]
                    }
                }
                coeffs[u * size + v] = sum
            }
        }
        let ac = coeffs[1...].sorted()
        let median = ac[ac.count / 2]
        var hash: UInt64 = 0
        for i in 0..<(size * size) where coeffs[i] > median {
            hash |= (UInt64(1) << UInt64(i))
        }
        return hash
    }

    private static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Drop near-duplicate photos across ALL sources (Google + website + cache),
    /// keeping the FIRST occurrence — so callers order the pool the way they want it
    /// shown, then dedup, and the best-ranked of a duplicate pair survives. Exact
    /// URL repeats go first; then pHash within `phashThreshold`. Photos without a
    /// pHash (shared-verdict / legacy-cache entries) are kept and only URL-deduped —
    /// we never drop a photo we can't actually compare.
    static func deduped(_ photos: [ScreenedPhoto]) -> [ScreenedPhoto] {
        var kept: [ScreenedPhoto] = []
        var keptHashes: [UInt64] = []
        var seenURLs = Set<String>()
        for photo in photos {
            guard seenURLs.insert(photo.url).inserted else { continue }
            if let h = photo.phash {
                if keptHashes.contains(where: { hamming($0, h) <= phashThreshold }) { continue }
                keptHashes.append(h)
            }
            kept.append(photo)
        }
        return kept
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
        // Feature prints of everything kept so far, so near-identical shots (same
        // job, seconds apart — common in Places pools) are dropped and the
        // mosaic/strip show distinct photos.
        var keptPrints: [VNFeaturePrintObservation] = []
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
                if let fp = decision.featurePrint {
                    if isNearDuplicate(fp, of: keptPrints) { continue }   // drop near-dupe
                    keptPrints.append(fp)
                }
                let photo = ScreenedPhoto(url: displayURL, labels: decision.labels, phash: decision.phash)
                if allowVehicles && decision.isVehicle { vehicle.append(photo) }
                else { other.append(photo) }
            }
            // Else: the photo couldn't be fetched — DROP it. We only ever display
            // images that actually load; reserving a tile for an unreachable URL is
            // what put empty gray containers in the mosaic (reported 2026-08-09).
            // The rule is "no picture, don't show it" — a business left with zero
            // fetchable photos is then dropped by the caller, and a transient miss
            // recovers on the next screen pass / pull-to-refresh. (Previously Places
            // URLs were kept here on the theory their key 403s transiently; the gray
            // tile that produced is worse than briefly missing a photo.)
        }
        let result = Array((vehicle + other).prefix(limit))   // display full-size, work shots first
        // A storefront/exterior alone is not a work photo — if nothing here is real
        // work, return none so the caller drops the business instead of leading with
        // its shop sign as the only picture.
        return hasWorkPhoto(result) ? result : []
    }

    /// Scene labels marking a shot of the *premises* (a shop's exterior / signage)
    /// rather than the actual work — from Apple Vision's generic scene tokens,
    /// which every kept photo retains even after rich-tag enrichment. Used only to
    /// break ties: a storefront never outranks a genuine work photo, but it still
    /// ranks above nothing when a business has only exterior shots.
    private static let premisesTokens: Set<String> = [
        "building", "buildings", "house", "facade", "storefront", "warehouse",
        "signboard", "billboard", "street", "sign", "signage",
    ]

    private static func isPremisesShot(_ labels: [String]) -> Bool {
        labels.contains { premisesTokens.contains($0) }
    }

    /// Purely PROMOTIONAL / branding shots — a shop storefront or window, signage,
    /// a flyer/menu/logo. These are never an example of the work itself. Kept
    /// DELIBERATELY NARROW: `building`/`house`/`facade` are NOT here, because a
    /// painted house, a re-roof, or new siding IS the work for those trades and
    /// must never be dropped. The tell for a storefront is the signage/branding,
    /// not the building.
    private static let promoTokens: Set<String> = [
        "storefront", "shopfront", "shop", "store", "signboard", "billboard",
        "signage", "sign", "poster", "advertisement", "flyer", "menu", "banner",
        "marquee", "logo", "brand", "text",
    ]

    private static func isPromoShot(_ labels: [String]) -> Bool {
        labels.contains { promoTokens.contains($0) }
    }

    /// Whether a screened set contains at least one genuine WORK photo — anything
    /// that isn't purely a promotional/storefront/signage shot. A house exterior
    /// (painting, roofing, siding) counts as work and is KEPT; only a business
    /// whose photos are all promo has nothing real to show, so the caller drops it
    /// rather than leading with a shop sign (reported 2026-08-10).
    static func hasWorkPhoto(_ photos: [ScreenedPhoto]) -> Bool {
        photos.contains { !isPromoShot($0.labels) }
    }

    /// Scene labels marking pure scenery / landmarks — a Golden Gate Bridge
    /// sunset is never a work example for ANY trade, unlike premises shots
    /// (which at least show the business). Deliberately narrow: no "sky",
    /// "water", "tree", "garden" etc., which appear on genuine roofing /
    /// plumbing / landscaping work photos alongside the work itself.
    private static let sceneryTokens: Set<String> = [
        "bridge", "skyline", "cityscape", "seascape", "sunset", "sunrise",
        "beach", "ocean", "coast", "shoreline", "mountain", "canyon",
        "monument", "landmark", "panorama", "horizon", "waterfall",
    ]

    private static func isSceneryShot(_ labels: [String]) -> Bool {
        labels.contains { sceneryTokens.contains($0) }
    }

    /// Premises or scenery — anything whose subject isn't the work.
    private static func isNonWorkShot(_ labels: [String]) -> Bool {
        isPremisesShot(labels) || isSceneryShot(labels)
    }

    /// Order kept photos so those whose labels match the query lead; among equally
    /// relevant shots, genuine work photos rank above storefront/exterior ones, and
    /// original order breaks any remaining tie. Returns display URLs, working off
    /// stored labels so it needs no re-download or re-classification. This surfaces
    /// the kitchen shot first for a "kitchen remodel" search — and, once photos are
    /// rich-tagged, the dented-bumper shot first for an auto body request.
    /// `capPremises` limits how many premises/storefront shots the result may
    /// contain — but only when the business also has at least one real work photo,
    /// so a premises-only business still shows its exterior rather than nothing.
    /// The list strip passes 1 (a card led with the shopfront twice — one big
    /// storefront tile plus a repeat — instead of the actual work); the gallery
    /// leaves it nil to page through everything.
    static func order(_ photos: [ScreenedPhoto], query: String, category: String = "",
                      capPremises: Int? = nil, vehicle: VehicleFilter? = nil) -> [String] {
        // Segregate by the Auto ⇄ Moto toggle first: a Moto search must never show
        // a car (even from a shop that services both), and vice-versa.
        let photos = matchingVehicle(photos, vehicle)
        let terms = query.lowercased()
            .split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 3 }
        // Dynamic per-request vocabulary (category + job description): the labels
        // to search for, generated after classification knows what the user
        // needs. Empty when the query has no subject term — scoring then falls
        // back to the raw terms, exactly as before.
        let visual = visualQuery(category: category, job: query)
        // Score once per photo (the old code re-scored inside the comparator).
        let jobScores = photos.map {
            visual.isEmpty ? matchScore($0.labels, terms)
                           : conceptMatchScore($0.labels, visual)
        }
        // Whether the job vocabulary matched nothing at all — the tiebreaks
        // below only apply then; a real job match always outranks them.
        let noJobMatch = jobScores.allSatisfy { $0 == 0 }
        // Trade fallback: when the job vocabulary matched nothing at all, prefer
        // photos showing the trade's kind of work over unrelated interiors.
        // Pure tiebreak — a real job match always outranks it.
        let tradeTerms = noJobMatch
            ? tradeFallbackTerms[category.lowercased()] : nil
        let sorted = photos.enumerated()
            .sorted { a, b in
                let sa = jobScores[a.offset], sb = jobScores[b.offset]
                if sa != sb { return sa > sb }
                // No photo matched the job: sink shots the vision tagger
                // confidently identified as a DIFFERENT specific job (a rooftop
                // AC unit leading a furnace search) below neutral work photos,
                // instead of letting Google upload order put a misleading shot
                // first.
                if noJobMatch {
                    let da = isDistractorJob(a.element.labels, visual)
                    let db = isDistractorJob(b.element.labels, visual)
                    if da != db { return !da }
                }
                if let tradeTerms {
                    let ta = matchScore(a.element.labels, tradeTerms)
                    let tb = matchScore(b.element.labels, tradeTerms)
                    if ta != tb { return ta > tb }
                }
                // Equal query relevance (incl. no query at all) → push premises /
                // scenery shots below real work photos.
                let pa = isNonWorkShot(a.element.labels)
                let pb = isNonWorkShot(b.element.labels)
                if pa != pb { return !pa }
                return a.offset < b.offset
            }
            .map(\.element)

        // Drop cross-source near-duplicates (Google shot re-uploaded on the site,
        // the same job re-added from cache) now that they're in final display
        // order, so the best-ranked of a duplicate pair is the one kept. The Vision
        // dedup in `screen()` only sees a single pool; this is the choke point every
        // display list flows through, so it catches dups the other sources introduce.
        var candidates = deduped(sorted)
        if candidates.contains(where: { !isSceneryShot($0.labels) }) {
            candidates.removeAll { isSceneryShot($0.labels) }
        }

        guard let cap = capPremises,
              candidates.contains(where: { !isPremisesShot($0.labels) }) else {
            return candidates.map(\.url)   // no cap, or nothing but premises → keep all
        }
        var premisesShown = 0
        return candidates.compactMap { photo in
            guard isPremisesShot(photo.labels) else { return photo.url }
            premisesShown += 1
            return premisesShown <= cap ? photo.url : nil
        }
    }

    /// Action verbs and generic shape/container words that describe *what's being
    /// done* or a *stock label shape*, never the specific fixture the user cares
    /// about. The badge must not fire on these alone: "replace" matches every
    /// `replacement` photo regardless of trade, and "bowl" matches Apple Vision's
    /// generic "bowl" label on sinks, dishes, and any round object — so "replaced
    /// toilet bowl" was badging (and promoting) businesses whose only hit was a
    /// non-toilet "bowl" shot (2026-07-18). Length ≤3 words ("new", "fix", "job")
    /// are already dropped by the >3 filter; this covers the ≥4-char ones.
    /// Positional/spatial words ("above", "below", "near") locate the job but
    /// never name it — "the ceiling above the garage door" is not a trim job,
    /// so they must not count as subject terms either (2026-09-13).
    private nonisolated static let nonSubjectTerms: Set<String> = [
        "replace", "replaced", "replacing", "replacement",
        "install", "installed", "installing", "installation",
        "repair", "repaired", "repairing", "fixed", "fixing",
        "remodel", "renovate", "renovation", "refinish", "refinished",
        "upgrade", "service", "maintenance", "clean", "cleaning",
        "broken", "damaged", "bowl", "unit", "area", "spot",
        "piece", "item", "work", "project", "need", "want",
        "above", "below", "under", "underneath", "beneath",
        "front", "back", "side", "sides", "outside", "around",
        "near", "behind", "beside", "across", "along", "between",
        // Business words — "roofing contractor" is a roofing job, and no photo
        // is ever labeled "contractor".
        "contractor", "contractors", "company", "companies", "business",
        "service", "services", "professional", "professionals",
        "specialist", "specialists", "expert", "experts",
        // Type/state adjectives Vision never emits as labels — "leaky"
        // describes the problem, not a visible object, so it can only dilute
        // the denominator ("sliding" is a door type no label names).
        "leaky", "leaking", "clogged", "cracked", "dripping", "loose",
        "sliding",
    ]

    /// The specific-subject terms of a query — its ≥4-char words minus the
    /// action/generic vocabulary above. "replaced toilet bowl" → ["toilet"].
    private nonisolated static func subjectTerms(_ query: String) -> [String] {
        query.lowercased()
            .split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 3 && !nonSubjectTerms.contains($0) }
    }

    // MARK: - Dynamic visual vocabulary

    /// A job-conditioned visual search vocabulary: the labels to search a
    /// contractor's screened photos for, derived AFTER the request is
    /// classified — from its category + job description — rather than from raw
    /// query words.
    ///
    /// Apple Vision's labels are generic scene nouns ("roof", "house",
    /// "siding"); the user's specific trade words ("metal trim", "breaker
    /// panel") essentially never appear in them, so matching raw query terms
    /// against labels scores 0 for every photo and the photo signal goes dead
    /// on specific jobs. The dynamic vocabulary bridges that gap: each subject
    /// term maps to the visual synonyms Vision actually emits for that thing.
    struct VisualQuery {
        /// One concept per subject term: the term plus its visual synonyms. A
        /// photo matches a concept when ANY of its labels matches ANY of the
        /// concept's words — synonyms only ever ADD ways to match; they never
        /// widen the denominator the way appending flat terms would.
        let concepts: [[String]]
        var isEmpty: Bool { concepts.isEmpty }
    }

    /// Visual synonyms: what Apple Vision calls the thing the user named.
    /// Conservative by design — only near-certain visual equivalents of the
    /// SAME visible object (a faucet IS a tap; trim IS molding/fascia), never
    /// loose scene associates — so a synonym can't promote an unrelated photo
    /// the way the old substring matching once did.
    private nonisolated static let visualSynonyms: [String: [String]] = [
        "metal": ["aluminum", "aluminium", "steel", "iron", "copper", "stainless"],
        "wood": ["lumber", "timber", "plank", "beam"],
        "wooden": ["wood", "lumber", "timber"],
        "vinyl": ["plastic", "pvc"],
        "trim": ["molding", "moulding", "casing", "fascia", "flashing"],
        "molding": ["trim", "casing", "fascia"],
        "casing": ["trim", "molding"],
        "flashing": ["trim", "fascia", "drip"],
        "fascia": ["trim", "soffit", "eave", "flashing"],
        "soffit": ["fascia", "eave"],
        "gutter": ["downspout", "eave"],
        "downspout": ["gutter", "eave"],
        "shingle": ["roof", "rooftop", "tile", "slate"],
        "roofing": ["roof", "rooftop", "shingle"],
        "roof": ["rooftop", "shingle"],
        "siding": ["cladding", "wall"],
        "cladding": ["siding", "wall"],
        "deck": ["patio", "porch"],
        "fence": ["gate", "railing"],
        "door": ["doorway", "gate"],
        "doorway": ["door"],
        "window": ["glazing"],
        "windshield": ["window", "glass"],
        "glass": ["window", "mirror"],
        "tire": ["wheel"],
        "wheel": ["tire", "rim"],
        "cabinet": ["cupboard", "vanity"],
        "vanity": ["cabinet", "sink"],
        "countertop": ["counter"],
        "counter": ["countertop"],
        "faucet": ["tap", "spigot"],
        "tap": ["faucet", "spigot"],
        "sink": ["basin", "faucet"],
        "basin": ["sink"],
        "toilet": ["commode"],
        "commode": ["toilet"],
        "shower": ["tub", "bathroom"],
        "tub": ["bathtub", "shower", "bathroom"],
        "bathtub": ["tub", "bathroom"],
        "pipe": ["piping"],
        "piping": ["pipe"],
        "drain": ["pipe"],
        "tile": ["floor", "backsplash"],
        "backsplash": ["tile"],
        "floor": ["flooring"],
        "flooring": ["floor", "tile", "wood"],
        "drywall": ["wall"],
        "wall": ["drywall"],
        "wire": ["wiring", "cable"],
        "wiring": ["wire", "cable"],
        "outlet": ["switch"],
        "switch": ["outlet"],
        "furnace": ["heater"],
        "heater": ["furnace"],
        // NOTE: "hvac" is deliberately NOT a synonym of anything here. It's a
        // trade hypernym, not a visible object: a mini-split, a furnace, and a
        // thermostat are all "hvac", so listing it made every hvac-tagged photo
        // "match" every hvac query. That silently disabled the distractor
        // demotion (noJobMatch never fired) and let the photo weight promote
        // the wrong evidence. Generic hvac photos still get preferred over
        // interiors via tradeFallbackTerms.
        "vent": ["duct"],
        "duct": ["vent"],
    ]

    /// Per-trade synonym overlays, keyed by lowercased classify category. The
    /// same word means different visible things per trade — "panel" is a
    /// breaker box to an electrician and a body panel to a paint shop — so the
    /// overlay resolves the word the way THAT trade's photos actually look.
    /// Applied on top of (never instead of) the global table; a trade-ambiguous
    /// word with no overlay entry simply gets no synonyms, rather than a wrong
    /// global one.
    private nonisolated static let tradeSynonyms: [String: [String: [String]]] = [
        "electrical": [
            "panel": ["breaker", "fuse", "box"],
            "box": ["panel", "breaker"],
        ],
    ]

    /// Trade-level visual fallback, keyed by lowercased classify category. When no
    /// screened photo matches the JOB specifically (every job-vocabulary score 0 —
    /// the common case for small jobs no portfolio names), `order` prefers photos
    /// that at least show the trade's kind of work over unrelated interiors: a
    /// carpentry job leads with the exterior woodwork shot, not a bathroom.
    /// Deliberately coarse — it only breaks ties the job vocabulary couldn't, and
    /// never outranks a real job match.
    private nonisolated static let tradeFallbackTerms: [String: [String]] = [
        "carpentry": ["wood", "lumber", "timber", "trim", "molding", "deck", "fence", "framing", "cabinet", "exterior", "house", "siding"],
        "painting": ["paint", "painting", "wall", "exterior", "house"],
        "roofing": ["roof", "rooftop", "shingle", "gutter", "exterior", "house", "ladder"],
        "flooring": ["floor", "flooring", "hardwood", "tile", "laminate", "carpet"],
        "plumbing": ["pipe", "piping", "faucet", "tap", "sink", "toilet", "bathroom"],
        "electrical": ["wire", "wiring", "panel", "breaker", "outlet", "light", "fixture"],
        "hvac": ["vent", "duct", "furnace", "heater", "hvac", "thermostat"],
        "landscaping": ["garden", "yard", "lawn", "patio", "landscape", "tree", "plant"],
        "windows & doors": ["window", "door", "doorway", "glass", "frame"],
        "appliances": ["refrigerator", "fridge", "dishwasher", "stove", "oven", "washer", "dryer", "appliance"],
        "mold & pest control": ["attic", "crawl", "basement"],
    ]

    /// Builds the dynamic visual vocabulary for one classified request, from
    /// the category + job description the request produced — the "change the
    /// labels dynamically" step: the labels we search photos for are generated
    /// per request, after we know what the user needs.
    private nonisolated static func visualQuery(category: String, job: String) -> VisualQuery {
        let overlay = tradeSynonyms[category.lowercased()] ?? [:]
        let concepts = subjectTerms(job).map { term -> [String] in
            Array(Set([term] + (visualSynonyms[term] ?? []) + (overlay[term] ?? [])))
        }
        return VisualQuery(concepts: concepts)
    }

    /// The vision tagger's `job:<noun>` assertion words — honored only when the
    /// photo's plain tags corroborate them (redundancy against a misfired
    /// assertion). Corroboration is word-level and prefix-tolerant ("furnaces"
    /// backs `job:furnace`; "gas furnace" backs `job:gas furnace`), or the
    /// whole noun phrase inside a plain label ("rooftop air conditioner
    /// unit"). A lone `job:furnace` with no furnace-ish plain tag is a likely
    /// model misread: it expands to nothing, so it scores neither as evidence
    /// nor as a distractor. The prompt already instructs the model to reuse
    /// its plain tag's canonical noun; this enforces it. Fails safe: an
    /// uncorroborated-but-correct assertion is ignored rather than trusted.
    private nonisolated static func corroboratedJobWords(_ labels: [String]) -> [String] {
        let plain = labels.filter { !$0.lowercased().hasPrefix("job:") }
        let plainWords = plain.flatMap {
            $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        return labels.flatMap { label -> [String] in
            let lower = label.lowercased()
            guard lower.hasPrefix("job:") else { return [] }
            let noun = String(lower.dropFirst(4))
            let words = noun.split(whereSeparator: { !$0.isLetter }).map(String.init)
            let backed = words.contains { w in plainWords.contains { matches($0, w) } }
                || plain.contains { $0.lowercased().contains(noun) }
            return backed ? words : []
        }
    }

    /// Expand the vision tagger's `job:<noun>` assertion tags into their words
    /// for relevance scoring, so `job:gas furnace` counts as furnace evidence
    /// the same way a plain "furnace" tag does. Plain labels pass through
    /// untouched; the `job:` prefix itself never scores (it would only add a
    /// constant prefix to every comparison). Assertions without corroboration
    /// (see corroboratedJobWords) contribute nothing. No-op for photos tagged
    /// before the tagger emitted `job:` tags.
    private nonisolated static func scoringLabels(_ labels: [String]) -> [String] {
        labels.filter { !$0.lowercased().hasPrefix("job:") } + corroboratedJobWords(labels)
    }

    /// True when the vision tagger confidently identified the photo as ONE
    /// specific job (`job:air conditioner`) and that job matches none of the
    /// search's concepts — a different job than the user asked for. Only
    /// consulted when the job vocabulary matched no photo at all; then such a
    /// shot is actively misleading as the lead photo (it asserts the business
    /// does THAT work, not the searched work) and sinks below neutral work
    /// shots. Guarded on a non-empty vocabulary: a query with no subject terms
    /// ("ac repair" — "ac" is too short to be a term) must not demote every
    /// job-tagged photo.
    private nonisolated static func isDistractorJob(_ labels: [String], _ visual: VisualQuery) -> Bool {
        guard !visual.isEmpty else { return false }
        let jobWords = corroboratedJobWords(labels)
        guard !jobWords.isEmpty else { return false }
        return !visual.concepts.contains { concept in
            jobWords.contains { word in concept.contains { matches(word, $0) } }
        }
    }

    /// Concept-level match: how many of the visual query's concepts the photo's
    /// labels hit. One concept = one subject term + its visual synonyms; ANY
    /// synonym hitting ANY label counts the concept as matched.
    private nonisolated static func conceptMatchScore(_ labels: [String], _ query: VisualQuery) -> Int {
        let labels = scoringLabels(labels)
        return query.concepts.reduce(0) { acc, concept in
            acc + (labels.contains { label in concept.contains { matches(label, $0) } } ? 1 : 0)
        }
    }

    /// Word tokens of a free-text review, for the same subject-term matching the
    /// photo labels use — so "…they replaced our **toilet**" matches a "toilet"
    /// query on whole-word/prefix equality, not a bare substring.
    private nonisolated static func reviewTokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }

    /// Scored version of the review-job match: the best review's distinct
    /// subject-term hits as a fraction of the query's subject terms (0…1).
    /// A continuous ranking signal — a review naming 3 of 4 terms outranks one
    /// naming 1 — where the old boolean needed a hard 2-term bar to claim a match.
    nonisolated static func reviewMatchStrength(_ reviews: [String], query: String) -> Double {
        let terms = subjectTerms(query)
        guard !terms.isEmpty else { return 0 }
        let best = reviews.map { matchScore(reviewTokens($0), terms) }.max() ?? 0
        return min(Double(best) / Double(terms.count), 1)
    }

    /// Scored photo-job match against the DYNAMIC visual vocabulary for the
    /// classified request (category + job description): the best screened
    /// photo's concept hits as a fraction of the job's subject concepts (0…1).
    /// Feeds ranking; per-photo display order stays with `order`.
    ///
    /// Because the vocabulary is built per request from what the user needs —
    /// not from raw query words — a "metal trim" job also matches photos Vision
    /// labeled "flashing" or "fascia", where the old raw-term match scored every
    /// photo 0. Reviews intentionally stay on raw subject terms: review text is
    /// already specific language, and synonym-expanding it would reopen the
    /// false-positive class the 2026-09-13 bar closed.
    nonisolated static func photoMatchStrength(_ photos: [ScreenedPhoto], query: String, category: String) -> Double {
        let visual = visualQuery(category: category, job: query)
        guard !visual.isEmpty, !photos.isEmpty else { return 0 }
        let best = photos.map { conceptMatchScore($0.labels, visual) }.max() ?? 0
        return min(Double(best) / Double(visual.concepts.count), 1)
    }

    /// Reviews reordered so the one that most specifically names the searched job
    /// leads; non-matching reviews keep their original relative order behind the
    /// matches. Generic over the review model via a `text` extractor. This is the
    /// single ordering both surfaces use, so the list card's quoted review and the
    /// gallery's first review are guaranteed to be the same one.
    nonisolated static func orderReviewsByJob<R>(_ reviews: [R], query: String, text: (R) -> String) -> [R] {
        let terms = subjectTerms(query)
        guard !terms.isEmpty else { return reviews }
        return reviews.enumerated()
            .sorted { a, b in
                let sa = matchScore(reviewTokens(text(a.element)), terms)
                let sb = matchScore(reviewTokens(text(b.element)), terms)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Index of the review the list card quotes. Exposed separately from the
    /// snippet so the caller can carry that review's *identity* to the gallery and
    /// pin the exact same one to the top of the sheet — the card shows only a
    /// sentence lifted from the middle of the review, so "the same text" is not
    /// something the two screens can match on after the fact.
    ///
    /// Ties keep the lowest index, the same tiebreak `orderReviewsByJob` uses.
    /// Same 2-term bar the old boolean check used: a quoted review must clear it
    /// threshold on multi-term queries, so the card never quotes an incidental
    /// one-word hit as the "why" behind the badge (2026-09-13).
    nonisolated static func mostRelevantReviewIndex(_ reviews: [String], query: String) -> Int? {
        let terms = subjectTerms(query)
        guard !terms.isEmpty else { return nil }
        let bar = min(2, terms.count)
        var best: (index: Int, score: Int)?
        for (i, text) in reviews.enumerated() {
            let score = matchScore(reviewTokens(text), terms)
            guard score >= bar else { continue }
            if best == nil || score > best!.score { best = (i, score) }
        }
        return best?.index
    }

    /// The single review that most specifically describes the searched job,
    /// trimmed to the sentence that actually names it — the customer's own words
    /// shown as the "why" behind a match on the list card. Nil when none mention
    /// it.
    nonisolated static func mostRelevantReview(_ reviews: [String], query: String) -> String? {
        guard let i = mostRelevantReviewIndex(reviews, query: query) else { return nil }
        return focusedSnippet(reviews[i], terms: subjectTerms(query))
    }

    /// The sentence within a review that names a subject term, so the quoted line
    /// shows the relevant words rather than a truncated opener. Falls back to the
    /// whole review if no single sentence isolates the match.
    private nonisolated static func focusedSnippet(_ text: String, terms: [String]) -> String {
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            if matchScore(reviewTokens(String(sentence)), terms) > 0 {
                return String(sentence).trimmingCharacters(in: .whitespaces)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Empty `terms` scores every photo 0, so ordering falls through to the
    /// premises/original-order tiebreaks — a plain category browse still leads
    /// with work shots over storefronts.
    ///
    /// A term matches a label on whole-word equality or a shared prefix — never a
    /// bare substring. Substring matching let a query term match the *middle or
    /// end* of an unrelated label: "door" matched "in**door**" / "out**door**"
    /// (labels Apple Vision stamps on nearly every room / exterior shot), so a
    /// window photo scored the same "door" point as a genuine door shot and the
    /// door search led with windows. Prefix matching keeps plurals / derivations
    /// ("window"→"windows", "door"→"doorway") while dropping the suffix collisions.
    private nonisolated static func matchScore(_ labels: [String], _ terms: [String]) -> Int {
        let labels = scoringLabels(labels)
        return terms.reduce(0) { acc, t in
            acc + (labels.contains { matches($0, t) } ? 1 : 0)
        }
    }

    /// One label token vs. one query term. Equal, or either is a prefix of the
    /// other — but only when the shorter string is itself ≥4 chars, so a stray
    /// short token can't prefix-match half the vocabulary.
    private nonisolated static func matches(_ label: String, _ term: String) -> Bool {
        if label == term { return true }
        let (short, long) = label.count <= term.count ? (label, term) : (term, label)
        return short.count >= 4 && long.hasPrefix(short)
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
