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
    /// folds the request together with the clarified answers), otherwise a
    /// synthesized paragraph built from the Q&A pairs — each answer joined to
    /// its question as one sentence, never invented copy. Either way it's the
    /// user's own stated facts.
    ///
    /// The overview REPLACES the base line rather than being appended to it.
    /// Appending both is what made the message repeat itself (the request and
    /// the size stated twice, e.g. "Repaint house 1070sq ft" then "…repainted,
    /// about 1070 sq ft"). One clean description. The synthesized fallback is
    /// genuinely additive (different content, not a restatement), so there
    /// appending is correct.
    func augmentedDescription(base: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let overview = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty { return overview }
        // No overview — the clarify backend returned an empty summary, or the
        // call failed. Synthesize one readable paragraph from the pairs rather
        // than dumping raw bullets (Igor 2026-09-19: the bullet dump read as a
        // regression). Purely mechanical: each answer joined to its question.
        // The opening user turn is the request itself; pairs exclude it, so it
        // has to be picked up separately here.
        let opening = turns.first(where: { $0.role == "user" })?
            .content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = trimmedBase.isEmpty ? opening : trimmedBase
        let details = pairs.compactMap { Self.qaSentence(question: $0.question, answer: $0.answer) }
        if details.isEmpty { return head }
        let paragraph = details.joined(separator: " ")
        return head.isEmpty ? paragraph : "\(head) \(paragraph)"
    }

    /// One Q&A pair as a single readable sentence:
    /// "How wide are the french doors? ~6 ft (wide pair)."
    /// Light cleanup only ("About how" → "How"); the words stay the user's own.
    private static func qaSentence(question: String, answer: String) -> String? {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return nil }
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.lowercased().hasPrefix("about how ") {
            q = "How " + q.dropFirst("about how ".count)
        }
        let qMarked = q.hasSuffix("?") ? q : q + "?"
        var sentence = "\(qMarked) \(a)"
        if !sentence.hasSuffix(".") { sentence += "." }
        return sentence
    }
}
