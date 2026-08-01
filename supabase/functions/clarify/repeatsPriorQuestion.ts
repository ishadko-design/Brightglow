// Deterministic guard against the clarifying chat re-asking an answered
// question. Extracted from index.ts so it is testable without booting
// Deno.serve, the same reason quickReplies.ts lives on its own.

/** True when `question` substantially repeats one an assistant turn already
 *  asked. Content-word Jaccard over the prior questions — normalized to catch
 *  "About how big is the garage floor?" vs "how big is the garage floor" — with
 *  a high threshold so a genuinely new question about the same noun ("what
 *  material" vs "what size") is not swallowed. */
export function repeatsPriorQuestion(
  question: string,
  messages: Array<{ role: string; content: string }>,
): boolean {
  const STOP = new Set([
    "the", "a", "an", "is", "are", "do", "you", "your", "what", "how", "of",
    "to", "in", "on", "for", "about", "this", "that", "it", "and", "or", "with",
    "want", "need", "have", "will", "be", "any",
  ]);
  const words = (t: string) =>
    new Set(
      t.toLowerCase().replace(/[^a-z0-9\s]/g, " ").split(/\s+/)
        .filter((w) => w.length > 2 && !STOP.has(w)),
    );
  const q = words(question);
  if (q.size === 0) return false;
  for (const m of messages) {
    if (m.role !== "assistant") continue;
    const prior = words(m.content);
    if (prior.size === 0) continue;
    let shared = 0;
    for (const w of q) if (prior.has(w)) shared++;
    const jaccard = shared / (q.size + prior.size - shared);
    if (jaccard >= 0.6) return true;
  }
  return false;
}
