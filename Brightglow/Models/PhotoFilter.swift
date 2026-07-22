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

    /// Outcome of screening one photo: whether to keep it, whether its subject
    /// is a vehicle (used to rank vehicle/work shots first for auto & moto), and
    /// its Vision feature print (a perceptual fingerprint used to drop
    /// near-duplicate shots so the mosaic/strip show distinct photos).
    struct Decision {
        let keep: Bool
        let isVehicle: Bool
        let labels: [String]
        var featurePrint: VNFeaturePrintObservation? = nil
    }
    private static let reject = Decision(keep: false, isVehicle: false, labels: [])

    /// Feature-print distance below which two photos read as the same shot. Google
    /// Places pools routinely include near-identical images (same job, seconds
    /// apart); smaller distance = more alike. Tuned to catch obvious dupes without
    /// merging genuinely different angles of the same job.
    private static let duplicateDistance: Float = 0.32

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
        return Decision(keep: true, isVehicle: isVehicle, labels: labels,
                        featurePrint: featurePrint(cg))
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
                let photo = ScreenedPhoto(url: displayURL, labels: decision.labels)
                if allowVehicles && decision.isVehicle { vehicle.append(photo) }
                else { other.append(photo) }
            } else {
                other.append(ScreenedPhoto(url: displayURL, labels: []))   // couldn't fetch to judge → keep
            }
        }
        return Array((vehicle + other).prefix(limit))   // display full-size, work shots first
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
    static func order(_ photos: [ScreenedPhoto], query: String,
                      capPremises: Int? = nil) -> [String] {
        let terms = query.lowercased()
            .split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 3 }
        let sorted = photos.enumerated()
            .sorted { a, b in
                let sa = matchScore(a.element.labels, terms)
                let sb = matchScore(b.element.labels, terms)
                if sa != sb { return sa > sb }
                // Equal query relevance (incl. no query at all) → push premises /
                // scenery shots below real work photos.
                let pa = isNonWorkShot(a.element.labels)
                let pb = isNonWorkShot(b.element.labels)
                if pa != pb { return !pa }
                return a.offset < b.offset
            }
            .map(\.element)

        // Scenery never earns a slot: drop it whenever the business has
        // anything else to show (a scenery-only gallery keeps its photos —
        // better a bridge than a blank card).
        var candidates = sorted
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
    private nonisolated static let nonSubjectTerms: Set<String> = [
        "replace", "replaced", "replacing", "replacement",
        "install", "installed", "installing", "installation",
        "repair", "repaired", "repairing", "fixed", "fixing",
        "remodel", "renovate", "renovation", "refinish", "refinished",
        "upgrade", "service", "maintenance", "clean", "cleaning",
        "broken", "damaged", "bowl", "unit", "area", "spot",
        "piece", "item", "work", "project", "need", "want",
    ]

    /// The specific-subject terms of a query — its ≥4-char words minus the
    /// action/generic vocabulary above. "replaced toilet bowl" → ["toilet"].
    private nonisolated static func subjectTerms(_ query: String) -> [String] {
        query.lowercased()
            .split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 3 && !nonSubjectTerms.contains($0) }
    }

    /// True when at least one of these screened photos actually matches the
    /// user's request — i.e. the business has a work photo of the kind of job
    /// being searched for. Drives the "Did similar job" trust cue on result cards
    /// (design brief §9). Unlike `order` (a soft ranking that may lean on any
    /// term, incl. the work type), the badge is a hard trust claim, so it requires
    /// a match on a *specific subject* term — not a generic shape or the action
    /// word — via `subjectTerms`. A query with no such term (a bare/short category
    /// browse, or a verb-only "renovation") can't establish similarity → false.
    nonisolated static func matchesQuery(_ photos: [ScreenedPhoto], query: String) -> Bool {
        let terms = subjectTerms(query)
        guard !terms.isEmpty else { return false }
        return photos.contains { matchScore($0.labels, terms) > 0 }
    }

    /// Word tokens of a free-text review, for the same subject-term matching the
    /// photo labels use — so "…they replaced our **toilet**" matches a "toilet"
    /// query on whole-word/prefix equality, not a bare substring.
    private nonisolated static func reviewTokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }

    /// True when a business's own review text names the searched job's subject —
    /// a customer describing the same work. Weaker proof than a screened photo,
    /// but it rides on review text we already fetch (no extra API cost) and lets
    /// a specialist surface without paying to screen its photos. Same
    /// `subjectTerms` basis as the photo badge, so both agree on what the job is
    /// and a generic/action word ("replace", "bowl") can't trip it alone.
    nonisolated static func reviewsMentionJob(_ reviews: [String], query: String) -> Bool {
        let terms = subjectTerms(query)
        guard !terms.isEmpty else { return false }
        let tokens = reviews.flatMap(reviewTokens)
        return matchScore(tokens, terms) > 0
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
    nonisolated static func mostRelevantReviewIndex(_ reviews: [String], query: String) -> Int? {
        let terms = subjectTerms(query)
        guard !terms.isEmpty else { return nil }
        var best: (index: Int, score: Int)?
        for (i, text) in reviews.enumerated() {
            let score = matchScore(reviewTokens(text), terms)
            guard score > 0 else { continue }
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
        terms.reduce(0) { acc, t in
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
