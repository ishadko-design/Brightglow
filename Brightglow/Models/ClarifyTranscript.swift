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

    /// The description to send to the business: the user's own words, then the
    /// AI's readable overview of the clarified job as a secondary description
    /// under an "Additional details (AI-generated)" label.
    ///
    /// The overview is a single comprehensive paragraph that already folds in the
    /// clarifying Q&A — the raw questions and answers are never shown. When the
    /// chat produced no overview (skipped, failed, or an older payload), there's
    /// nothing trustworthy to add, so just `base` is returned.
    func augmentedDescription(base: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let overview = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else { return trimmedBase }
        let block = "Additional details (AI-generated):\n\(overview)"
        return trimmedBase.isEmpty ? block : "\(trimmedBase)\n\n\(block)"
    }
}
