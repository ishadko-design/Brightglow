// Tappable-option handling for the clarifying chat.
//
// Extracted from index.ts so it can be unit-tested: importing index.ts starts
// Deno.serve, the same reason estimatePipeline.ts lives outside the pricing
// function's entrypoint.
//
// Reported live 2026-07-22: "Is this pipe inside the house, or the main line to
// the street/septic?" rendered with no chips at all. The client was fine and the
// server usually returns options — the model simply judged that this either/or
// had no "natural options", which the prompt at the time explicitly permitted.

/** Last-resort options when the model gives none and a retry also fails.
 *
 *  Deliberately NOT derived from the question text. Splitting "A, or B?" and
 *  trimming each side reads fine in the abstract but produces mid-phrase
 *  garbage in practice — the reported question yields "This pipe inside the"
 *  and "Main line to the", which look broken to a user. Reliable noun-phrase
 *  extraction is not a regex problem, so the recovery path that DOES read well
 *  is asking the model again (see index.ts); this is the floor beneath that. */
export const GENERIC_REPLIES = ["Yes", "No", "Not sure"];

/** Normalize whatever the model returned: trim, drop blanks and over-long
 *  labels that would overflow a chip, de-duplicate, cap at 4.
 *
 *  Returns `usable: false` when fewer than 2 options survive, which is the
 *  caller's signal to retry. One option is as much a dead end as none — there
 *  is nothing to choose between. */
export function normalizeQuickReplies(
  raw: unknown,
): { replies: string[]; usable: boolean } {
  const cleaned = (Array.isArray(raw) ? raw : [])
    .map((r) => (typeof r === "string" ? r.trim() : ""))
    .filter((r) => r.length > 0 && r.length <= 24);
  const replies = [...new Set(cleaned)].slice(0, 4);
  return { replies, usable: replies.length >= 2 };
}
