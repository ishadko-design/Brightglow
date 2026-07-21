// LLM fallback classifier for the `pricing` Edge Function.
//
// Runs only when keyword classification misses (or lands on a category-general
// entry despite a real description) — the long tail of phrasings like "replace
// the glass slider to the backyard" that no keyword list anticipates. The model
// is constrained by a structured-output enum to the existing taxonomy ids plus
// "none": it maps text to a job type, never to a price, so the app-wide rule
// (every displayed number comes from EstimationPro data) is preserved. "none"
// keeps the honest "coming soon" fallback for text that fits nothing.
//
// Secrets: supabase secrets set ANTHROPIC_API_KEY=<key>  (unset = classifier
// silently off, keyword behavior unchanged).

import Anthropic from "npm:@anthropic-ai/sdk";
import type { JobTypeEntry } from "./pricingEngine.ts";

/** Entries the model may choose from: the category's specific job types plus
 *  its general (hourly/typical) entry — or the whole taxonomy when the client
 *  sent no category. Empty for categories with no coverage (Mold & Pest
 *  Control), which callers treat as "skip the LLM entirely". */
export function buildClassifierPool(
  taxonomy: JobTypeEntry[],
  generals: Record<string, JobTypeEntry | null>,
  category: string,
): JobTypeEntry[] {
  const generalEntries = Object.values(generals)
    .filter((e): e is JobTypeEntry => e !== null);
  const pool = [...taxonomy, ...generalEntries];
  return category ? pool.filter((e) => e.category === category) : pool;
}

export function buildSystemPrompt(pool: JobTypeEntry[]): string {
  const lines = pool.map((e) => {
    const hint = e.keywords.length > 0
      ? `e.g. ${e.keywords.join(", ")}`
      : `general ${e.category.toLowerCase()} work, when nothing more specific fits`;
    return `- ${e.job_type} (${e.category}; ${hint})`;
  });
  return [
    "You classify a free-text service request into one job type from a fixed",
    "taxonomy, for a local cost estimate. Requests cover both home trades and",
    "vehicle work (cars and motorcycles).",
    "",
    "Rules:",
    '- Pick the single job type that best matches the work described.',
    "- When several fit, pick the most specific: a material- or item-specific",
    '  entry beats a generic "replacement" or "general" one ("replace asphalt',
    '  shingle roof" is the shingle entry, not the generic roof replacement —',
    "  specific entries price by size and give tighter estimates).",
    '- Answer "none" when the request does not clearly fit any listed job',
    "  type — never force a fit. A wrong match displays a wrong price, which",
    "  is worse than showing no price.",
    '- Match on the work, not incidental words ("water pooling under the',
    '  dishwasher" is a plumbing leak, not an appliance job).',
    "",
    "Report the vertical: \"auto\" for anything about a car, truck or",
    'motorcycle; "home" for property work; "none" if genuinely unclear. This',
    "matters because the home taxonomy owns the generic words: a request to",
    'replace a car\'s "rear quarter window" must not become a house window.',
    "",
    "Also report the vehicle, because it changes both the parts and the count:",
    "a car tire set is 4, a motorcycle's is 2, and moto labor is priced",
    "differently. Infer it from ANY signal in the text — the word motorcycle,",
    'a marque or model ("Ducati", "Yamaha R6", "Harley", "Vespa"), or a',
    'colloquialism ("my bike", "two-wheeler"). This is why it is your job and',
    "not a word list: the space of ways people name a motorcycle is open-ended.",
    '- "moto" for motorcycles, scooters, mopeds, dirt bikes, ATVs.',
    '- "auto" for cars, trucks, vans, SUVs.',
    '- "none" for home-trade requests, or vehicle work where the text gives no',
    "  indication which — never guess between auto and moto on no evidence.",
    "",
    "Job types:",
    ...lines,
  ].join("\n");
}

/** Structured-output schema: the model cannot answer outside the pool. */
export function buildSchema(pool: JobTypeEntry[]): Record<string, unknown> {
  return {
    type: "object",
    properties: {
      job_type: {
        type: "string",
        enum: [...pool.map((e) => e.job_type), "none"],
      },
      vehicle: {
        type: "string",
        enum: ["auto", "moto", "none"],
      },
      vertical: {
        type: "string",
        enum: ["home", "auto", "none"],
      },
    },
    required: ["job_type", "vehicle", "vertical"],
    additionalProperties: false,
  };
}

export interface Classification {
  /** Pool job_type, or null for "none"/unknown — keyword result stands. */
  jobType: string | null;
  /** Vehicle the text implies, or null when it says nothing. */
  vehicle: "auto" | "moto" | null;
  /** Which taxonomy the request belongs to, or null when unclear. Keeps a car
   *  window out of the home window entry. */
  vertical: "home" | "auto" | null;
}

/** Parses the model's JSON reply. Anything malformed degrades to nulls, which
 *  mean "keyword result stands" — the classifier never hard-fails a request. */
export function parseClassification(
  text: string | undefined,
  pool: JobTypeEntry[],
): Classification {
  const empty: Classification = { jobType: null, vehicle: null, vertical: null };
  if (!text) return empty;
  try {
    const o = JSON.parse(text) as {
      job_type?: unknown;
      vehicle?: unknown;
      vertical?: unknown;
    };
    return {
      jobType: pool.some((e) => e.job_type === o.job_type) ? o.job_type as string : null,
      vehicle: o.vehicle === "auto" || o.vehicle === "moto" ? o.vehicle : null,
      vertical: o.vertical === "home" || o.vertical === "auto" ? o.vertical : null,
    };
  } catch {
    return empty;
  }
}

export async function classifyWithLLM(
  pool: JobTypeEntry[],
  description: string,
  apiKey: string,
): Promise<Classification> {
  if (pool.length === 0 || !apiKey) return { jobType: null, vehicle: null, vertical: null };
  const client = new Anthropic({ apiKey, timeout: 15_000, maxRetries: 1 });
  const response = await client.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 300,
    system: buildSystemPrompt(pool),
    output_config: { format: { type: "json_schema", schema: buildSchema(pool) } },
    messages: [{ role: "user", content: `Request: ${description}` }],
  });
  const textBlock = response.content.find((b) => b.type === "text");
  return parseClassification(textBlock?.text, pool);
}
