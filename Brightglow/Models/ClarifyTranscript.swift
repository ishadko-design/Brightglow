import Foundation

/// The clarifying Q&A captured on the landing, threaded through the results and
/// gallery to the quote-request screen. Its purpose is to enrich the message a
/// business receives: the request sent out is the user's own words *plus* an
/// AI-clarified detail block built from the questions the chat asked and the
/// answers the user gave — so the business gets the full picture, not just the
/// one-line request.
struct ClarifyTranscript: Equatable {
    /// Full turn list as it appeared in the chat: the first turn is the user's
    /// original request, then alternating assistant question / user answer.
    var turns: [ClarifyService.Turn]

    /// The AI's plain-English overview of the job (from the clarify outcome),
    /// combining the request with the confirmed answers into one readable note
    /// for the business. Empty when the chat didn't produce one.
    var summary: String = ""
    /// 3-5 word job title from the clarify LLM ("metal trim replacement").
    /// Empty when the chat was skipped or couldn't name the request.
    var jobTitle: String = ""

    static let empty = ClarifyTranscript(turns: [])

    /// One clarifying exchange — a question the chat asked and the user's answer.
    struct Pair: Identifiable, Equatable {
        let id = UUID()
        let question: String
        let answer: String
    }

    /// The question/answer pairs, excluding the opening request. Empty when the
    /// chat never asked anything (skipped, failed, or not configured).
    var pairs: [Pair] {
        var out: [Pair] = []
        var pendingQuestion: String? = nil
        for turn in turns {
            if turn.role == "assistant" {
                pendingQuestion = turn.content
            } else if turn.role == "user", let question = pendingQuestion {
                out.append(Pair(question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                                answer: turn.content.trimmingCharacters(in: .whitespacesAndNewlines)))
                pendingQuestion = nil
            }
        }
        return out
    }

    /// Nothing was clarified — only the original request (or nothing) is present.
    var isEmpty: Bool { pairs.isEmpty }

    /// The description to send to the business: the chat's readable overview of
    /// the clarified job when it produced one (a single paragraph that already
    /// folds the request together with the clarified answers), otherwise the
    /// raw conversation — the opening request plus the Q&A pairs as details.
    /// Either way it's the user's own stated facts, never invented copy.
    ///
    /// The overview REPLACES the base line rather than being appended to it.
    /// Appending both is what made the message repeat itself (the request and
    /// the size stated twice, e.g. "Repaint house 1070sq ft" then "…repainted,
    /// about 1070 sq ft"). One clean description. The raw Q&A fallback is
    /// genuinely additive (different content, not a restatement), so there
    /// appending is correct.
    func augmentedDescription(base: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let overview = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty { return overview }
        // No overview (skipped, failed, or an older payload) — assemble from the
        // raw conversation. The opening user turn is the request itself; pairs
        // exclude it, so it has to be picked up separately here.
        let opening = turns.first(where: { $0.role == "user" })?
            .content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = trimmedBase.isEmpty ? opening : trimmedBase
        if pairs.isEmpty { return head }
        let qa = pairs.map { "• \($0.question)\n  \($0.answer)" }.joined(separator: "\n")
        return head.isEmpty ? qa : "\(head)\n\nDetails:\n\(qa)"
    }
}
