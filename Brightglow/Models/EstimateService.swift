import Foundation
import CoreLocation

/// Local price estimates for a job.
///
/// Phase 1 (current): a cloud LLM produces a low–high range from the trade,
/// the job description, and the user's locality, so the figure tracks both the
/// kind of work and the area.
///
/// Phase 2 (planned): once accepted quotes are collected, a median-by-category-
/// and-ZIP lookup should override the LLM for areas with real data. Keep that
/// swap local to `estimate(...)` — callers shouldn't care which source answered.
enum EstimateService {

    private static let hfToken: String =
        (Bundle.main.object(forInfoDictionaryKey: "HF_TOKEN") as? String) ?? ""

    private static let model = "Qwen/Qwen3-VL-8B-Instruct"

    /// A locally-aware price range for a job, or nil if it can't be produced.
    ///
    /// `priceHints` are real dollar amounts pulled from nearby contractors' reviews
    /// (see `priceMentions`). When present they ground the LLM in actual local
    /// prices rather than a pure guess.
    static func estimate(category: Category, job: String,
                         locality: String, priceHints: [Int] = []) async -> PriceTier? {
        let work = job.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = work.isEmpty ? category.rawValue.lowercased() : work
        let place = locality.isEmpty ? "the United States" : locality

        let grounding = priceHints.isEmpty ? "" :
            "Customers in this area recently reported these prices in reviews: "
            + priceHints.sorted().map { "$\($0)" }.joined(separator: ", ")
            + ". Treat them as the strongest signal for the local range. "

        let prompt =
            "You are a home and auto repair cost estimator. "
            + grounding
            + "Give a realistic LOCAL price range "
            + "in US dollars for a \(category.rawValue) job described as \"\(descriptor)\" "
            + "in \(place). Account for regional labor and material costs. "
            + "Reply with ONLY two integers as \"min-max\" (e.g. 250-900). No words, no $ signs."

        guard let (lo, hi) = await complete(prompt) else { return nil }
        return PriceTier(label: "Estimated", min: lo, max: hi)
    }

    /// Extract plausible dollar amounts mentioned in review text — a real,
    /// hyper-local price signal to anchor the estimate. Keeps values in a sane
    /// services range and returns an evenly-spread sample.
    static func priceMentions(in reviews: [Review], limit: Int = 12) -> [Int] {
        guard let rx = try? NSRegularExpression(pattern: #"\$\s?([0-9][0-9,]{1,6})"#) else { return [] }
        var found: [Int] = []
        for review in reviews {
            let text = review.text + " " + (review.originalText ?? "")
            let ns = text as NSString
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
                if let v = Int(raw), (20...100_000).contains(v) { found.append(v) }
            }
        }
        let unique = Array(Set(found)).sorted()
        guard unique.count > limit else { return unique }
        let step = Double(unique.count) / Double(limit)        // even spread, not just the low end
        return (0..<limit).map { unique[Int(Double($0) * step)] }
    }

    /// Reverse-geocode a coordinate to a "City, ST" locality string.
    static func locality(for coord: CLLocationCoordinate2D) async -> String {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return "" }
        return [mark.locality, mark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    // MARK: - LLM call

    private static func complete(_ prompt: String) async -> (Int, Int)? {
        guard !hfToken.isEmpty,
              let url = URL(string: "https://router.huggingface.co/v1/chat/completions")
        else { return nil }

        let payload: [String: Any] = [
            "model": model, "max_tokens": 16,
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }

        return parseRange(content)
    }

    /// Pull "min-max" out of the model's reply, tolerating $, commas, "to", "k".
    private static func parseRange(_ text: String) -> (Int, Int)? {
        let nums = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
            .compactMap { Int($0) }
            .filter { $0 > 0 }
        guard nums.count >= 2 else { return nil }
        let lo = min(nums[0], nums[1]), hi = max(nums[0], nums[1])
        return lo == hi ? nil : (lo, hi)
    }
}
