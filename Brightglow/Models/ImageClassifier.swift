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

    // 30B MoE (~3B active params): near-8B latency, much better scene reading —
    // the 8B kept calling floor coverings "Carpentry".
    private static let model = "Qwen/Qwen3-VL-30B-A3B-Instruct"

    /// Built from the live category lists so the options always match the app
    /// (no hand-maintained list to drift). The model first decides the vertical
    /// (vehicle vs home), then picks one category from that vertical.
    private static let prompt: String = {
        let home = Category.allCases.map(\.rawValue).joined(separator: ", ")
        let auto = autoCategoryItems.map(\.name).joined(separator: ", ")
        return "You route a repair request to the right contractor from one photo.\n"
            + "STEP 1 — PICK THE SUBJECT (do this FIRST, before choosing a category). "
            + "Choose the SINGLE thing the request is about. Prefer the physically "
            + "LARGEST built fixture the shot is framed around — a vanity, cabinet, "
            + "sink, countertop, bathtub, shower surround, appliance, water heater, "
            + "window, glass/patio door, or roof — EVEN WHEN smaller, higher-contrast "
            + "hardware is also in view. A large fixture near the CENTER of the frame "
            + "BEATS small hardware (a faucet, valve, handle, knob, spout, hinge, "
            + "cartridge) near the EDGE of the frame: do NOT pick a small edge object "
            + "over a large central one. Pick the small part ONLY when the photo is "
            + "clearly a tight CLOSE-UP of it — it fills most of the frame. Pick "
            + "EXACTLY ONE subject; never merge two (not \"faucet and valve\", not "
            + "\"door and floor\"). Ignore the floor, tiles, rug, wall, and ceiling "
            + "unless the camera clearly points DOWN at the floor with no fixture in "
            + "view. Leave DESCRIPTION empty only for a truly featureless wide shot (a "
            + "whole-house exterior from afar, an empty yard).\n"
            + "STEP 2 — ROUTE IT. Decide whether that ONE subject is a VEHICLE (car, "
            + "truck, or motorcycle, or a part of one) or part of a HOME / property. "
            + "Then choose exactly ONE category:\n"
            + "- If it's a vehicle, choose from: \(auto).\n"
            + "- If it's a home/property, choose from: \(home).\n"
            + "Always answer with one of those SPECIFIC category names — never just "
            + "\"Vehicle\" or \"Home\". If unsure which, pick the closest and append a \"?\".\n"
            + "Note: floors and floor coverings (hardwood, laminate, tile, carpet, rugs) "
            + "are Flooring — NOT Carpentry. Carpentry is furniture, cabinets, trim, "
            + "framing, decks.\n"
            + "Reply on EXACTLY ONE line as: CATEGORY | DETAILS | DESCRIPTION — no "
            + "preamble, no second line, and never repeat this template in your answer.\n"
            + "CATEGORY is the chosen category name, exactly as written above. If you can "
            + "pick a category but are not certain, append a question mark (e.g. Carpentry?).\n"
            + "DETAILS is a short comma-separated list of attributes visible in the photo. "
            + "For a VEHICLE, DETAILS must START with the vehicle type (car, truck, or "
            + "motorcycle) and — when a badge or the body shape makes it legible — the make, "
            + "model, and colour, then the visible issue: e.g. \"car, Honda Civic sedan, "
            + "silver, front bumper dent\" or \"motorcycle, Harley-Davidson cruiser, black\". "
            + "For a HOME subject, list attributes useful for a repair cost estimate — size, "
            + "capacity (gallons, amps, BTU), material, or type (e.g. \"40 gallon, tankless, "
            + "gas\" or \"30 inch, vinyl\"). For a window or door, note its operation (sliding, "
            + "casement, double-hung), a rough size only if you can judge it (e.g. \"~5x4 ft\"), "
            + "and any visible scope cue (a fogged/cracked pane vs. the whole unit). Only "
            + "include what's actually visible — never guess a make, dimension, condition, or "
            + "problem you can't see. Write \"none\" if nothing relevant is visible.\n"
            + "DESCRIPTION is ONE short line the user could send as their request, as you "
            + "understand it — START WITH AN ACTION VERB (Replace, Repair, Fix, Install) and "
            + "name the ONE subject you chose above with ONE action. Never combine several "
            + "objects or list multiple problems (not \"repair the door and the floor\"): pick "
            + "the single spotlight subject and describe only what's needed for THAT. Name a "
            + "fixture by its MAIN noun and do NOT list its built-in parts — a vanity already "
            + "includes its sink and countertop, so write \"Replace the bathroom vanity\", never "
            + "\"vanity with sink and countertop\". Fold in "
            + "the make/model, type, material or colour. Include a SIZE ONLY when the photo actually shows it — a legible or "
            + "standard dimension, or a clear room/panel boundary you can judge — otherwise "
            + "leave the size out rather than guessing. For a fixture, name its type when "
            + "visible (gas vs electric, tank vs tankless). Examples: \"Replace large French "
            + "door, about 72x80\", \"Replace hardwood floor\" (size not visible), \"Repair gas "
            + "furnace\", \"Body repair for blue Chevrolet Volt — large dents on front door and "
            + "fender\". Under ~12 words, plain words, no label, no trailing period.\n"
            + "VEHICLE EXCEPTION: for a car or motorcycle, write a DESCRIPTION ONLY when a "
            + "concrete problem is actually VISIBLE — collision or dent, a scratch/scrape, "
            + "cracked or shattered glass, a flat/shredded tire, a fluid leak or puddle, rust, "
            + "or a broken or missing part. If the vehicle simply looks normal (the likely "
            + "problem is mechanical or internal and NOT visible in the photo), write DESCRIPTION "
            + "as \"none\" — do NOT invent an action like \"Repair car\" or \"Replace part\". The "
            + "user, not the app, should say what's wrong when it can't be seen; a made-up "
            + "suggestion they have to delete is worse than a blank box. (DETAILS still records "
            + "the visible vehicle type, make, model, and colour — only DESCRIPTION is withheld.)\n"
            + "Reply only the single word 'unsure' when there is genuinely NO home or vehicle "
            + "repair subject in view at all — e.g. a person, a pet, food, or plain sky. A normal "
            + "room interior is NOT unsure: name its most prominent fixture."
    }()

    // MARK: - Public API

    /// Best-guess trade (home or auto) — cloud first, on-device Vision fallback.
    static func classify(_ image: UIImage) async throws -> TradeMatch {
        if let cloud = try? await classifyCloud(image) { return cloud.match }
        return try classifyOnDevice(image)
    }

    /// Classify only the region the user circled.
    static func classify(_ image: UIImage, regionInView rect: CGRect, viewSize: CGSize) async throws -> TradeMatch {
        let target = crop(image, viewRect: rect, viewSize: viewSize) ?? image
        return try await classify(target)
    }

    /// A single cloud verdict. `isConfident` is false when the model hedged
    /// (appended "?" per the prompt protocol). `details` is a short, comma-
    /// separated list of visible cost-relevant attributes (size, capacity,
    /// material) — nil when nothing relevant was visible or the model wasn't
    /// confident enough to trust its category call in the first place.
    struct Suggestion { let match: TradeMatch; let isConfident: Bool; let details: String?; let description: String? }

    /// Ordered guesses for the capture flow, best first: the cloud verdict (when
    /// available) then the on-device Vision guess. `confident` is set only when
    /// the cloud model answered without hedging — that one may be preselected;
    /// everything else only leads the category carousel. `details` carries the
    /// cloud verdict's visible attributes (material, size, vehicle type) whether
    /// or not the category was confident — they're observations, not a category
    /// call, and clarify needs them to avoid re-asking. `vehicle` is the
    /// cloud model's car-vs-motorcycle read (from the vehicle words it leads
    /// DETAILS with) — nil when the subject isn't a vehicle or the model didn't
    /// name the type; the caller falls back to the on-device `detectVehicleType`.
    /// `description` is the cloud model's ready-to-show phrase for the subject and
    /// its problem ("Blue Chevrolet Volt with large dents on the front door"),
    /// used to auto-fill the capture input — kept whether or not the category was
    /// confident, like `details`. nil when the model left it empty or was offline.
    struct Suggestions { let matches: [TradeMatch]; let confident: TradeMatch?; let details: String?; let vehicle: VehicleFilter?; let description: String? }

    /// Re-run capture classification on just the region the user circled. The
    /// drawn area is a strong "THIS is the subject" signal that overrides a
    /// whole-frame read which latched onto something more prominent — e.g. circled
    /// kitchen cabinets in a shot the whole-frame guess called "hardwood floor"
    /// (reported 2026-08-08). `rect` is in the draw canvas's view space; it's
    /// padded a little so a tight loop doesn't clip the subject's edges.
    static func suggestTrades(_ image: UIImage, regionInView rect: CGRect, viewSize: CGSize) async -> Suggestions {
        let pad = CGRect(x: rect.minX - rect.width * 0.12, y: rect.minY - rect.height * 0.12,
                         width: rect.width * 1.24, height: rect.height * 1.24)
        let target = crop(image, viewRect: pad, viewSize: viewSize) ?? image
        // A drawn region is an explicit "read THIS" — never run the area/abstain gate
        // on it, or a small circled part could be judged "nothing dominates".
        return await suggestTrades(target, applyAreaGate: false)
    }

    /// Whole-image classification for **auto-suggesting** tags. (The drawing path
    /// still uses the plain `classify`, which always returns a single best guess —
    /// the user pointed at it.)
    static func suggestTrades(_ image: UIImage, applyAreaGate: Bool = true) async -> Suggestions {
        var matches: [TradeMatch] = []
        var confident: TradeMatch? = nil
        var details: String? = nil
        var description: String? = nil
        var vehicle: VehicleFilter? = nil
        // The on-device saliency crop is used ONLY for the weak on-device fallback
        // below — NEVER for the cloud vision model. Saliency over-picks a big
        // high-texture foreground (a patterned rug, a tile floor), so cropping to
        // it fed the strong model a floor and it dutifully returned "floor tiles" /
        // "hardwood floor" for photos plainly framed on a window, door, or vanity
        // (reported repeatedly 2026-08-09). The cloud VLM reads the WHOLE scene far
        // better than an on-device saliency guess picks the subject — the prompt's
        // subject-priority rule handles "which fixture" — so it gets the full image.
        let subject: UIImage = dominantObject(image).flatMap { cropNormalized(image, $0) } ?? image
        // Surface-area gate: decide ON-DEVICE whether a SINGLE object clearly owns
        // the frame before trusting a guess. Two things gate on this:
        //   1. a text HINT to the cloud VLM (still the whole image, never a crop —
        //      see the note above), and
        //   2. a HARD suppression below — because the VLM does NOT reliably obey the
        //      "answer unsure" hint on a busy frame. A cluttered kitchen and a
        //      door-in-a-room both still auto-filled a confident wrong description
        //      ("kitchen sink faucet", "hardwood floor") even though nothing
        //      dominated (reported 2026-08-17). So when no object is both big AND
        //      clearly larger than the runner-up, we don't guess at all: no auto-
        //      fill, no preselect — the user says what they want. A big spotlighted
        //      subject (a vanity at ~35%) still anchors the read as before.
        // Circled regions bypass the gate (applyAreaGate == false): the loop already
        // IS the "this is the subject" signal.
        let dominance: SubjectDominance = applyAreaGate
            ? subjectDominance(image)
            : .dominant(area: 1, center: CGPoint(x: 0.5, y: 0.5))
        let dominates: Bool = { if case .dominant = dominance { return true } else { return false } }()
        let hint = applyAreaGate ? hint(for: dominance) : nil
        if let cloud = try? await cloudReply(image, hint: hint) {
            // DETAILS and DESCRIPTION are visible observations, independent of
            // whether the CATEGORY parsed to a known service — so keep them even
            // when the model hedged with "?" OR answered with a bare vertical word
            // ("Vehicle") that maps to no category. Discarding them on those was
            // why clear photos re-asked the fence material (2026-08-07) and showed
            // no auto-description (2026-08-08). `match`-gated things (carousel,
            // vehicle read, confident preselect) still require a real match.
            details = cloud.details
            // Only auto-fill a description / preselect a tag when ONE subject clearly
            // owns the frame. In an ambiguous frame (several roughly-equal objects),
            // leave the input blank rather than guess a wrong subject.
            description = dominates ? cloud.description : nil
            if let match = cloud.match {
                matches.append(match)
                // When the cloud model saw a vehicle it leads DETAILS with the
                // type (car/truck/motorcycle) — read car-vs-moto from there even
                // if the category itself was hedged, so clarify never re-asks it.
                if case .auto = match { vehicle = vehicleFilter(from: cloud.details) }
                if cloud.isConfident, dominates { confident = match }
            }
        }
        // The on-device guess always contributes a carousel suggestion (never a
        // preselection) — it often catches what the cloud model mislabels, e.g.
        // a rug reads as Flooring here while the model may say Carpentry.
        if let device = try? classifyOnDevice(subject, minConfidence: onDeviceMinConfidence),
           !matches.contains(device) {
            matches.append(device)
        }
        // Vehicle type is meaningful ONLY when the subject really is a vehicle.
        // If the cloud named a car/moto it already set `vehicle`; otherwise fall
        // back to the on-device vehicle classifier — but gated on an AUTO subject,
        // so a car parked in the background of a home photo can never set a vehicle
        // type. Without this gate a 10%-of-frame car in a house photo flipped the
        // request to the auto path and clarify asked "car, SUV, or truck?" for a
        // house repaint (reported 2026-07-26).
        let subjectIsAuto = matches.contains { if case .auto = $0 { return true } else { return false } }
        if vehicle == nil, subjectIsAuto { vehicle = detectVehicleType(subject) }
        return Suggestions(matches: matches, confident: confident, details: details, vehicle: subjectIsAuto ? vehicle : nil, description: description)
    }

    /// Fraction of the frame a single salient object must exceed to be treated as
    /// THE subject, overriding a whole-image read that could otherwise fixate on a
    /// smaller, more visually salient distractor. Tunable.
    private static let dominantAreaFraction: CGFloat = 0.5

    /// The bounding box of the single salient object occupying more than
    /// `dominantAreaFraction` of the frame, or nil when nothing clearly dominates.
    /// On-device saliency, normalized Vision coords (origin bottom-left).
    private static func dominantObject(_ image: UIImage) -> CGRect? {
        guard let cg = image.normalizedUp().cgImage else { return nil }
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        guard let obs = req.results?.first as? VNSaliencyImageObservation,
              let biggest = obs.salientObjects?.max(by: { area($0.boundingBox) < area($1.boundingBox) })
        else { return nil }
        return area(biggest.boundingBox) > dominantAreaFraction ? biggest.boundingBox : nil
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    /// Fraction the single largest salient region must reach to count as a dominant
    /// subject the cloud read should anchor to. Below it, nothing clearly dominates
    /// and the read abstains rather than guess. Measured 2026-08-12: a vanity fills
    /// ~35% (passes), a floor lamp in a busy room is ~7% (abstains). Tunable.
    private static let dominantHintFraction: CGFloat = 0.18

    /// How much bigger the largest salient object must be than the next-largest to
    /// count as the clear "spotlight" subject. When the top two are closer than this
    /// the frame holds several competing subjects of roughly equal weight, so the
    /// read abstains instead of guessing one. Tunable.
    private static let dominantRatio: CGFloat = 1.6

    /// On-device verdict on whether ONE object clearly owns the frame.
    /// `.dominant` = big AND clearly larger than the runner-up → trust a guess.
    /// `.ambiguous`/`.none` = several roughly-equal objects, or nothing salient →
    /// don't guess (auto-fill nothing, preselect nothing).
    private enum SubjectDominance {
        case dominant(area: CGFloat, center: CGPoint)
        case ambiguous(topArea: CGFloat)
        case none
    }

    /// Decide whether a single salient object is both big enough and clearly the
    /// spotlight subject. Vision saliency, normalized coords (origin bottom-left);
    /// the centre is flipped to top-left for the centrality test.
    private static func subjectDominance(_ image: UIImage) -> SubjectDominance {
        guard let cg = image.normalizedUp().cgImage else { return .none }
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        guard let obs = req.results?.first as? VNSaliencyImageObservation,
              let objects = obs.salientObjects, !objects.isEmpty else { return .none }
        let boxes = objects.map(\.boundingBox).sorted { area($0) > area($1) }
        let top = boxes[0]
        let topArea = area(top)
        let runnerUp = boxes.count > 1 ? area(boxes[1]) : 0
        // "Big and in the spotlight": clears the area floor AND clearly outsizes the
        // next-biggest. With no meaningful runner-up (runnerUp == 0) the top object
        // stands alone. When the top two are close in size, several subjects compete.
        let spotlight = runnerUp <= 0 || topArea >= runnerUp * dominantRatio
        if topArea >= dominantHintFraction && spotlight {
            return .dominant(area: topArea, center: CGPoint(x: top.midX, y: 1 - top.midY))
        }
        return .ambiguous(topArea: topArea)
    }

    /// The subject hint handed to the cloud VLM alongside the whole image. It
    /// mirrors the on-device dominance verdict: anchor on a clear subject, or ask
    /// the model to abstain when nothing dominates. (The on-device gate enforces
    /// the abstain regardless of whether the model obeys — see `suggestTrades`.)
    private static func hint(for dominance: SubjectDominance) -> String {
        switch dominance {
        case let .dominant(area, center):
            let pct = Int((area * 100).rounded())
            let central = (0.3...0.7).contains(center.x) && (0.3...0.7).contains(center.y)
            return "\nSUBJECT HINT (from an on-device detector): one object fills about "
                + "\(pct)% of the frame\(central ? ", near the CENTER" : "") — this is almost "
                + "certainly the subject. Identify and describe THAT object; do not pick a "
                + "smaller item elsewhere in the frame."
        case let .ambiguous(topArea):
            let pct = Int((topArea * 100).rounded())
            return "\nSUBJECT HINT (from an on-device detector): NO single object dominates the "
                + "frame — several objects are of roughly equal size (the largest is only about "
                + "\(pct)%). If there is no clearly repairable home or vehicle FIXTURE that "
                + "dominates the shot, answer exactly 'unsure' rather than guessing a minor item "
                + "(a rug, a cushion, a plant, a small object)."
        case .none:
            return "\nSUBJECT HINT (from an on-device detector): NO single object stands out in "
                + "the frame. If there is no clearly repairable home or vehicle FIXTURE that "
                + "dominates the shot, answer exactly 'unsure' rather than guessing."
        }
    }

    /// Read car-vs-motorcycle from the cloud model's DETAILS string (it leads
    /// with the vehicle type for vehicles). nil when no vehicle word is present.
    private static func vehicleFilter(from details: String?) -> VehicleFilter? {
        guard let l = details?.lowercased() else { return nil }
        let moto = ["motorcycle", "motorbike", "moped", "scooter", "dirt bike", "cruiser", "sportbike"]
        let car = ["car", "truck", "van", "sedan", "suv", "pickup", "coupe", "hatchback", "automobile", "vehicle"]
        if moto.contains(where: l.contains) { return .moto }
        if car.contains(where: l.contains) { return .auto }
        return nil
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

    /// The parsed vision reply. `match` is nil when the model answered with a
    /// vertical word ("Vehicle", "Home / property") or anything that doesn't map
    /// to a known category — but `details` and `description` are still filled, so
    /// the capture input can auto-fill and the estimate can use the attributes
    /// even when the exact service wasn't named. (Reported 2026-08-08: clear
    /// photos produced no auto-description because the whole verdict was thrown
    /// away whenever the category came back as a bare vertical word.)
    private struct CloudReply {
        let match: TradeMatch?
        let isConfident: Bool
        let details: String?
        let description: String?
    }

    /// Network + parse. Throws only when the model was unreachable or replied a
    /// bare "unsure" (no usable content at all) — NOT when the category is merely
    /// unmappable, so `details`/`description` survive that case.
    private static func cloudReply(_ image: UIImage, hint: String? = nil) async throws -> CloudReply {
        guard !hfToken.isEmpty else { throw ClassifyError.noMatch }
        guard let jpeg = image.downscaled(maxDimension: 512).jpegData(compressionQuality: 0.7),
              let url = URL(string: "https://router.huggingface.co/v1/chat/completions")
        else { throw ClassifyError.noImage }

        let dataURI = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let payload: [String: Any] = [
            "model": model, "max_tokens": 90,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": prompt + (hint ?? "")],
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
        // A trailing "?" is the model hedging: keep the guess but mark it weak.
        if content.lowercased().contains("unsure") { throw ClassifyError.unsure }

        // "CATEGORY | DETAILS | DESCRIPTION" — parse only the FIRST non-empty line.
        // The model occasionally appends extra lines (a repeated format header, a
        // second guess); without this, DESCRIPTION captured all of it and the raw
        // "Repair | DETAILS | none | …" template leaked into the input field
        // (reported 2026-08-09). One line in, three fields out.
        let firstLine = content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? content
        let parts = firstLine.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let categoryText = parts.first ?? firstLine
        let detailsText = parts.count > 1 ? parts[1] : ""
        let details: String? = (detailsText.isEmpty || detailsText.lowercased() == "none") ? nil : detailsText
        let descriptionText = parts.count > 2 ? parts[2] : ""
        let description: String? = (descriptionText.isEmpty || descriptionText.lowercased() == "none") ? nil : descriptionText

        // A category we can't map -> nil match (not a thrown-away verdict). The
        // model naming a bare vertical word is common, and its DETAILS/DESCRIPTION
        // are still good.
        return CloudReply(match: try? matchTrade(in: categoryText),
                          isConfident: !categoryText.contains("?"),
                          details: details,
                          description: description)
    }

    /// A single cloud verdict with a MAPPED category — used by the plain
    /// `classify` paths that need a category. Throws when the model didn't name a
    /// category we recognize, so those callers fall back to the on-device guess.
    private static func classifyCloud(_ image: UIImage) async throws -> Suggestion {
        let reply = try await cloudReply(image)
        guard let match = reply.match else { throw ClassifyError.unsure }
        return Suggestion(match: match, isConfident: reply.isConfident,
                          details: reply.details, description: reply.description)
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
            // Credit only the category with the most specific (longest) keyword hit
            // per label, so "hardwood" counts for Flooring ("hardwood") and doesn't
            // also feed Carpentry via the looser "wood".
            var bestHome: (cat: Category, len: Int)? = nil
            for cat in Category.allCases {
                var len = cat.keywords.filter { label.contains($0) }.map(\.count).max() ?? 0
                if label.contains(cat.rawValue.lowercased()) { len = max(len, cat.rawValue.count) }
                if len > (bestHome?.len ?? 0) { bestHome = (cat, len) }
            }
            if let bestHome { homeScores[bestHome.cat, default: 0] += obs.confidence }
            var bestAuto: (idx: Int, len: Int)? = nil
            for (i, a) in autoCategoryItems.enumerated() {
                if let len = a.keywords.filter({ label.contains($0) }).map(\.count).max(),
                   len > (bestAuto?.len ?? 0) { bestAuto = (i, len) }
            }
            if let bestAuto { autoScores[bestAuto.idx, default: 0] += obs.confidence }
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

extension UIImage {
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
