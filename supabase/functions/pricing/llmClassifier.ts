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
    "You classify a homeowner's free-text repair request into one job type",
    "from a fixed taxonomy, for a local cost estimate.",
    "",
    "Rules:",
    '- Pick the single job type that best matches the work described.',
    '- Answer "none" when the request does not clearly fit any listed job',
    "  type — never force a fit. A wrong match displays a wrong price, which",
    "  is worse than showing no price.",
    '- Match on the work, not incidental words ("water pooling under the',
    '  dishwasher" is a plumbing leak, not an appliance job).',
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
    },
    required: ["job_type"],
    additionalProperties: false,
  };
}

/** Parses the model's JSON reply to a pool job_type, or null for "none",
 *  unknown ids, or malformed output — all of which mean "keyword result
 *  stands". */
export function parseJobType(
  text: string | undefined,
  pool: JobTypeEntry[],
): string | null {
  if (!text) return null;
  try {
    const value = (JSON.parse(text) as { job_type?: unknown }).job_type;
    return pool.some((e) => e.job_type === value) ? value as string : null;
  } catch {
    return null;
  }
}

export async function classifyWithLLM(
  pool: JobTypeEntry[],
  description: string,
  apiKey: string,
): Promise<string | null> {
  if (pool.length === 0 || !apiKey) return null;
  const client = new Anthropic({ apiKey, timeout: 15_000, maxRetries: 1 });
  const response = await client.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 300,
    system: buildSystemPrompt(pool),
    output_config: { format: { type: "json_schema", schema: buildSchema(pool) } },
    messages: [{ role: "user", content: `Request: ${description}` }],
  });
  const textBlock = response.content.find((b) => b.type === "text");
  return parseJobType(textBlock?.text, pool);
}
