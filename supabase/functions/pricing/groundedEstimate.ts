// Web-search-grounded cost band for jobs the in-house engine doesn't model.
//
// The catalog prices a fixed taxonomy of discrete jobs. Whole-room remodels
// ("full gut remodel of my bathroom, ~60 sq ft") have no entry, so the engine
// honestly declines — but a homeowner still wants a ballpark. This asks Opus,
// with the web_search tool, for a TYPICAL local low/typical/high for the
// described project, and returns it as a WIDE, low-confidence band labelled as
// an estimate to confirm with bids. It is the coverage tier of last resort:
// only runs after the modelled path declines, gated to substantial home jobs,
// and cached hard because it's the function's most expensive call.
//
// The number is grounded (a real search), never a catalog number — so it can't
// pretend to catalog precision. The guardrail below rejects anything that isn't
// a plausible, self-consistent home-project range; a rejected band means we go
// back to declining, never to a fabricated figure.

import Anthropic from "npm:@anthropic-ai/sdk";

export interface GroundedBand {
  low: number;
  typical: number;
  high: number;
  basis: string;
}

/** Pull the band JSON out of the model's final text. Defensive: the model may
 *  wrap it in prose, so we take the last {...} object. Anything malformed
 *  returns null, which the caller treats as "no estimate" (the honest decline),
 *  never a partial guess. */
export function parseGroundedBand(text: string | undefined): GroundedBand | null {
  if (!text) return null;
  const matches = text.match(/\{[\s\S]*?\}/g);
  if (!matches) return null;
  // Try the objects from last to first — the answer is usually the final one.
  for (const raw of matches.reverse()) {
    try {
      const o = JSON.parse(raw) as Record<string, unknown>;
      const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : NaN);
      const low = num(o.low);
      const typical = num(o.typical);
      const high = num(o.high);
      if ([low, typical, high].every(Number.isFinite)) {
        return {
          low,
          typical,
          high,
          basis: typeof o.basis === "string" ? o.basis : "",
        };
      }
    } catch { /* try the next candidate */ }
  }
  return null;
}

/** Sanity guardrail: a grounded band is only usable if it's a plausible,
 *  self-consistent range for a job a homeowner pays a contractor for. This is
 *  what keeps a hallucinated or misread search result off the screen — a
 *  rejected band drops us back to an honest decline. */
export function saneBand(b: GroundedBand | null): GroundedBand | null {
  if (!b) return null;
  const { low, typical, high } = b;
  if (!(low > 0 && typical > 0 && high > 0)) return null;
  if (!(low <= typical && typical <= high)) return null;
  // Floor: nothing a contractor takes on is a real all-in job under ~$50.
  if (low < 50) return null;
  // Ceiling: past a whole-home rebuild it isn't a "job estimate" any more —
  // more likely a misread (a per-unit or commercial figure).
  if (high > 500_000) return null;
  // A 20x span is noise, not an estimate — refuse to present it as one.
  if (high / low > 20) return null;
  return b;
}

export function buildGroundedSystemPrompt(locationLabel: string): string {
  return [
    "You estimate what a homeowner typically pays a contractor, all-in (labor +",
    `materials), for a described home project in ${locationLabel}.`,
    "",
    "Use the web_search tool to find RECENT, LOCAL cost data for this specific",
    "project and scope — cost guides, remodeling reports, local contractor",
    "ranges. Prefer sources that match the location and the stated size/scope.",
    "",
    "Then answer with ONLY a JSON object, no prose around it:",
    '{"low": <number>, "typical": <number>, "high": <number>, "basis": "<one short line: what drives this range + a source type>"}',
    "",
    "Rules:",
    "- Whole dollars, all-in for the WHOLE project as described (not per unit,",
    "  not per sq ft, not labor-only).",
    "- low/typical/high are the realistic spread for this scope in this area —",
    "  wide is fine and honest, but low <= typical <= high.",
    "- Respect the stated size and scope: a 60 sq ft gut bath is not a 200 sq ft",
    "  one; a partial refresh is not a full gut.",
    "- If you genuinely cannot find enough to estimate, return",
    '  {"low": 0, "typical": 0, "high": 0, "basis": "insufficient data"} — do',
    "  not guess a number with no basis.",
  ].join("\n");
}

/** Runs the grounded estimate. Returns a sane band, or null when the model
 *  declined, the search failed, or the band didn't pass the guardrail — all of
 *  which the caller renders as the honest "get bids" decline. Never throws to
 *  the caller: a grounded-tier failure must not fail the whole request. */
export async function groundedBand(
  description: string,
  locationLabel: string,
  apiKey: string,
): Promise<GroundedBand | null> {
  if (!apiKey || description.trim().length < 12) return null;
  const client = new Anthropic({ apiKey, timeout: 30_000, maxRetries: 1 });
  // web_search_20260209 (dynamic filtering) is supported on Opus 4.6+ — the
  // classifier already runs claude-opus-4-8, so the same model serves here.
  const tools = [{ type: "web_search_20260209", name: "web_search", max_uses: 4 }];
  const system = buildGroundedSystemPrompt(locationLabel);
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: `Project: ${description}` }];

  try {
    // Server-tool turns can pause_turn while the search runs; resume by echoing
    // the assistant's partial content back until it finishes.
    let resp = await client.messages.create({
      model: "claude-opus-4-8",
      max_tokens: 1500,
      system,
      // deno-lint-ignore no-explicit-any
      tools: tools as any,
      messages,
    });
    let guard = 0;
    while (resp.stop_reason === "pause_turn" && guard++ < 4) {
      messages.push({ role: "assistant", content: resp.content });
      resp = await client.messages.create({
        model: "claude-opus-4-8",
        max_tokens: 1500,
        system,
        // deno-lint-ignore no-explicit-any
        tools: tools as any,
        messages,
      });
    }
    const text = resp.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("\n");
    const band = saneBand(parseGroundedBand(text));
    // "insufficient data" comes back as an all-zero band, which saneBand
    // already rejects (low > 0 fails) — so it lands as null here, correctly.
    return band;
  } catch (err) {
    console.error("pricing: grounded estimate failed", err);
    return null;
  }
}
