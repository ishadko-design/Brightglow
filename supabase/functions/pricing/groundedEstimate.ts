// Web-search-grounded cost band for jobs the in-house engine doesn't model.
//
// The catalog prices a fixed taxonomy of discrete jobs. Whole-room remodels
// ("full gut remodel of my bathroom, ~60 sq ft") have no entry, so the engine
// honestly declines — but a homeowner still wants a ballpark. This asks the
// model (Sonnet 5, low effort) for a TYPICAL local low/typical/high from its
// own knowledge of current costs, and returns it as a WIDE, low-confidence band
// labelled as an estimate to confirm with bids. It is the coverage tier of last
// resort: only runs after the modelled path declines, gated to substantial
// jobs, and cached by a canonical job key so common phrasings reuse one answer.
//
// Knowledge-based, not live-searched: cost ranges move slowly, so a fast
// (~2s) knowledge estimate is a fine ballpark and avoids the 20-30s + per-
// request cost of web search (which added little to a figure the model already
// knows). The guardrail below rejects anything that isn't a plausible,
// self-consistent range; a rejected band means we decline, never fabricate.

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

/** What domain the request belongs to — sets who pays whom and what "all-in"
 *  means (materials for a home job, parts for a vehicle), and keeps a car job
 *  from being priced as home work. */
export type GroundedKind = "home" | "auto" | "moto";

export function buildGroundedSystemPrompt(locationLabel: string, kind: GroundedKind): string {
  const subject = kind === "moto"
    ? {
      payer: "what a rider typically pays a shop, all-in (labor + parts),",
      work: "the described work on their motorcycle",
      noun: "job",
      scope:
        "Respect the stated scope, model and parts — a minor service is not a major job, and the specific motorcycle changes the parts.",
    }
    : kind === "auto"
    ? {
      payer: "what a vehicle owner typically pays a shop, all-in (labor + parts),",
      work: "the described work on their car or truck",
      noun: "job",
      scope:
        "Respect the stated scope, model and parts — a minor service is not a major job, and the specific vehicle changes the parts.",
    }
    : {
      payer: "what a homeowner typically pays a contractor, all-in (labor + materials),",
      work: "a described home project",
      noun: "project",
      scope:
        "Respect the stated size and scope — a 60 sq ft gut bath is not a 200 sq ft one; a partial refresh is not a full gut.",
    };
  return [
    `You estimate ${subject.payer} for ${subject.work} in ${locationLabel}.`,
    "",
    `Price it from your own knowledge of typical current costs for this ${subject.noun}`,
    "and scope — the ranges cost guides, industry reports, and local shops or",
    "contractors generally quote. Adjust for this location's cost level.",
    "",
    "Answer with ONLY a JSON object, no prose around it:",
    '{"low": <number>, "typical": <number>, "high": <number>, "basis": "<one short line: what drives this range>"}',
    "",
    "Rules:",
    `- Whole dollars, all-in for the WHOLE ${subject.noun} as described (not per`,
    "  unit, not labor-only).",
    "- low/typical/high are the realistic spread for this scope in this area —",
    "  wide is fine and honest, but low <= typical <= high.",
    `- ${subject.scope}`,
    `- BROAD ${subject.noun}s (a remodel, renovation, addition, or other`,
    "  whole-room/whole-house job) where the user did NOT pin an exact size or",
    "  finish are still estimable: give a realistic range for a STANDARD version",
    "  of that project in this area, widen the spread to reflect the uncertainty,",
    '  and say so in the basis (e.g. "typical range, varies widely by size &',
    '  finish"). Do NOT refuse just because the scope is broad — a ballpark the',
    "  user can sanity-check beats no number at all.",
    "- Only when there is genuinely NO cost basis at all (an unintelligible or",
    "  non-estimable request) return",
    '  {"low": 0, "typical": 0, "high": 0, "basis": "insufficient data"} — do',
    "  not guess a number with no basis.",
  ].join("\n");
}

// Rooms/areas a whole-project request names. Used to collapse phrasings to one
// canonical cache key — see canonicalJob.
export const CANONICAL_SUBJECTS = [
  "bathroom", "kitchen", "basement", "garage", "attic", "bedroom", "living room",
  "laundry room", "closet", "deck", "patio", "whole house", "whole home", "adu",
  "accessory dwelling",
];

/** Collapse the many ways to phrase one job to a single canonical key, so common
 *  requests reuse ONE cached grounded band instead of paying per phrasing —
 *  "kitchen remodel", "remodel my kitchen", "kitchen renovation" all key to
 *  "kitchen:remodel". This is what makes the grounded tier financially scalable:
 *  real traffic collapses onto a handful of keys. Returns null when no subject
 *  is recognized, and the caller falls back to the full normalized text (the
 *  old per-phrasing behavior — safe, just a lower hit rate). Tradeoff: a stated
 *  size (a 60 sq ft bath vs a bare bathroom remodel) collapses into the same
 *  bucket — acceptable for a wide "confirm with bids" ballpark. */
export function canonicalJob(description: string): string | null {
  const d = description.toLowerCase();
  const subject = CANONICAL_SUBJECTS.find((s) => d.includes(s));
  if (!subject) return null;
  const ptype = /\bgut\b/.test(d)
    ? "gut-remodel"
    : /remodel|renovat|\breno\b/.test(d)
    ? "remodel"
    : /addition|adu|accessory dwelling/.test(d)
    ? "addition"
    : /rebuild|reconstruct/.test(d)
    ? "rebuild"
    : "remodel";
  const subjectKey = subject.replace(/\s+/g, "-").replace("whole-home", "whole-house");
  return `${subjectKey}:${ptype}`;
}

/** Structured-output schema — the model returns exactly this, so there's no
 *  JSON-in-prose to fish out. */
const BAND_SCHEMA = {
  type: "object",
  properties: {
    low: { type: "number" },
    typical: { type: "number" },
    high: { type: "number" },
    basis: { type: "string" },
  },
  required: ["low", "typical", "high", "basis"],
  additionalProperties: false,
} as const;

/** Prices the job from the model's own knowledge — fast (~2s) and cheap, no
 *  live web search. Cost ranges move slowly, so a knowledge estimate is a solid
 *  ballpark "confirm with bids" number; live search cost 20-30s and a per-
 *  request API bill for little gain on a figure the model already knows well
 *  (verified 2026-09-19: knowledge-only priced a terse kitchen remodel in 1.3s
 *  vs 30s for a searched bathroom, comparable ranges). Returns a sane band or
 *  null (→ the honest decline). Never throws to the caller. */
export async function groundedBand(
  description: string,
  locationLabel: string,
  apiKey: string,
  kind: GroundedKind,
): Promise<GroundedBand | null> {
  if (!apiKey || description.trim().length < 12) return null;
  // A key that isn't scoped to a workspace must send the workspace id as a
  // header (Anthropic rejects the request otherwise). No-op unless the env is
  // set / when the key is already workspace-scoped.
  const workspaceId = Deno.env.get("ANTHROPIC_WORKSPACE_ID");
  const client = new Anthropic({
    timeout: 20_000,
    maxRetries: 1,
    apiKey,
    ...(workspaceId ? { defaultHeaders: { "anthropic-workspace-id": workspaceId } } : {}),
  });
  try {
    // Sonnet 5 at low effort: a cost ballpark doesn't need Opus or deep thinking,
    // and this is the request-path latency the user waits on. ~1/5 the Opus cost.
    const resp = await client.messages.create({
      model: "claude-sonnet-5",
      max_tokens: 500,
      output_config: { effort: "low", format: { type: "json_schema", schema: BAND_SCHEMA } },
      system: buildGroundedSystemPrompt(locationLabel, kind),
      messages: [{ role: "user", content: `Project: ${description}` }],
    });
    const text = resp.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("\n");
    // "insufficient data" comes back as an all-zero band, which saneBand rejects
    // (low > 0 fails) — so it lands as null here, correctly.
    return saneBand(parseGroundedBand(text));
  } catch (err) {
    console.error("pricing: grounded estimate failed", err);
    return null;
  }
}
