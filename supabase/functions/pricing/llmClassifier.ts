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

export function buildSystemPrompt(pool: JobTypeEntry[], categoryHint?: string): string {
  const lines = pool.map((e) => {
    const hint = e.keywords.length > 0
      ? `e.g. ${e.keywords.join(", ")}`
      : `general ${e.category.toLowerCase()} work, when nothing more specific fits`;
    const guidance = e.guidance ? ` ${e.guidance}` : "";
    return `- ${e.job_type} (${e.category}; ${hint}).${guidance}`;
  });
  return [
    "You classify a free-text service request into job types from a fixed",
    "taxonomy, for a local cost estimate. Requests cover both home trades and",
    "vehicle work (cars and motorcycles).",
    "",
    "Rules:",
    "- A request can describe MORE THAN ONE distinct job (\"repair the siding",
    '  and fix the roof\' is two jobs: the siding job and the roof job). Split',
    "  it: return one entry per distinct job, each with the job_type that best",
    '  matches THAT job and a "detail" field quoting the words of the request',
    "  that describe that job (a contiguous quote when possible, otherwise a",
    "  faithful near-quote — never invent details the request did not state).",
    "- Order jobs as the request lists them. Never merge two trades into one",
    "  entry, and never split one job into two.",
    "- A single-job request returns a single entry.",
    '- When several types fit one job, pick the most specific: a material- or',
    '  item-specific entry beats a generic "replacement" or "general" one',
    '  ("replace asphalt shingle roof" is the shingle entry, not the generic',
    "  roof replacement — specific entries price by size and give tighter",
    "  estimates).",
    '- Answer with an empty jobs list when the request does not clearly fit',
    "  any listed job type — never force a fit. A wrong match displays a",
    "  wrong price, which is worse than showing no price.",
    '- Match on the work, not incidental words ("water pooling under the',
    '  dishwasher" is a plumbing leak, not an appliance job).',
    ...(categoryHint
      ? [
        "",
        `The user browsed the "${categoryHint}" category — prefer its entries`,
        "when the work fits, but the request may span trades; classify what",
        "the work actually is.",
      ]
      : []),
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
      jobs: {
        type: "array",
        maxItems: 3,
        items: {
          type: "object",
          properties: {
            job_type: {
              type: "string",
              enum: [...pool.map((e) => e.job_type), "none"],
            },
            detail: {
              type: "string",
              description:
                "The words of the request describing this job, quoted contiguously when possible.",
            },
          },
          required: ["job_type", "detail"],
          additionalProperties: false,
        },
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
    required: ["jobs", "vehicle", "vertical"],
    additionalProperties: false,
  };
}

export interface ClassifiedJob {
  /** Pool job_type, or null for "none"/unknown — that job is dropped. */
  jobType: string | null;
  /** The request's own words describing this job; priced in isolation. */
  detail: string;
}

export interface Classification {
  /** One entry per distinct job in the request, in listed order. Empty means
   *  "none" — the keyword result stands. */
  jobs: ClassifiedJob[];
  /** Vehicle the text implies, or null when it says nothing. */
  vehicle: "auto" | "moto" | null;
  /** Which taxonomy the request belongs to, or null when unclear. Keeps a car
   *  window out of the home window entry. */
  vertical: "home" | "auto" | null;
}

/** Parses the model's JSON reply. Anything malformed degrades to no jobs,
 *  which means "keyword result stands" — the classifier never hard-fails a
 *  request. */
export function parseClassification(
  text: string | undefined,
  pool: JobTypeEntry[],
): Classification {
  const empty: Classification = { jobs: [], vehicle: null, vertical: null };
  if (!text) return empty;
  try {
    const o = JSON.parse(text) as {
      jobs?: unknown;
      job_type?: unknown;
      vehicle?: unknown;
      vertical?: unknown;
    };
    // Backwards tolerance: the pre-multi-job schema returned a single job_type.
    const rawJobs = Array.isArray(o.jobs)
      ? o.jobs
      : o.job_type !== undefined
      ? [{ job_type: o.job_type, detail: "" }]
      : [];
    const jobs: ClassifiedJob[] = [];
    for (const j of rawJobs) {
      if (typeof j !== "object" || j === null) continue;
      const jt = (j as { job_type?: unknown }).job_type;
      const detail = (j as { detail?: unknown }).detail;
      jobs.push({
        jobType: pool.some((e) => e.job_type === jt) ? jt as string : null,
        detail: typeof detail === "string" ? detail : "",
      });
      if (jobs.length >= 3) break;
    }
    return {
      jobs,
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
  categoryHint?: string,
): Promise<Classification> {
  if (pool.length === 0 || !apiKey) return { jobs: [], vehicle: null, vertical: null };
  const client = new Anthropic({ apiKey, timeout: 15_000, maxRetries: 1 });
  const response = await client.messages.create({
    model: "claude-opus-4-8",
    max_tokens: 600,
    system: buildSystemPrompt(pool, categoryHint),
    output_config: { format: { type: "json_schema", schema: buildSchema(pool) } },
    messages: [{ role: "user", content: `Request: ${description}` }],
  });
  const textBlock = response.content.find((b) => b.type === "text");
  return parseClassification(textBlock?.text, pool);
}
