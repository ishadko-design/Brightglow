// LLM price-estimate fallback for the `pricing` Edge Function.
//
// The in-house engine prices only the jobs its catalog models. Everything
// else (a job type we don't carry yet, a classification miss, an entry the
// engine declines) used to return "Insufficient data. Get 3 bids", which
// shows no price at all. Product decision (2026-09-23): no price is worse
// than an honest rough one, so those requests fall back to asking the model
// for a local range. The catalog stays primary whenever it has an answer.
//
// The model returns numbers only through a structured-output schema, and
// every reply is sanity-checked (see validateEstimate). Anything implausible
// degrades to the old decline rather than showing a made-up figure.
// Confidence is always "low" and the label says where the number came from.
//
// Secrets: ANTHROPIC_API_KEY (unset = fallback off, declines as before).

import Anthropic from "npm:@anthropic-ai/sdk";

export interface LLMEstimate {
  low: number;
  typical: number;
  high: number;
}

export interface LLMEstimateInput {
  description: string;
  category: string;
  zip?: string;
  /** Two-letter state for the zip, when known — regional context for the model. */
  state?: string | null;
  vehicle?: "auto" | "moto" | null;
}

const SYSTEM_PROMPT = [
  "You estimate what a customer in the United States typically pays a",
  "professional for a service job, for a local price guide in a consumer app.",
  "",
  "Price the WHOLE job as the customer would be quoted: labor, materials or",
  "parts, disposal, and any permit the job normally needs, in current (2026)",
  "US dollars. Adjust for the stated location's cost of living and trade",
  "wages. Price the request as described, reading its stated size, count and",
  "scope; when a detail is missing, assume the most common version of the job.",
  "",
  "low is roughly the 20th percentile of real quotes, high roughly the 80th,",
  "typical the median. Keep the range as tight as honest uncertainty allows.",
  "",
  "Set priceable to false (and all numbers to 0) when the request is not a",
  "service job a local professional would quote, when it is too vague to",
  "price at all, or when it is a product purchase with no labor.",
].join("\n");

const SCHEMA = {
  type: "object",
  properties: {
    priceable: { type: "boolean" },
    low: { type: "number" },
    typical: { type: "number" },
    high: { type: "number" },
  },
  required: ["priceable", "low", "typical", "high"],
  additionalProperties: false,
} as const;

/** Bounds on what we'll display. A reply outside them is a model error, not a
 *  price: below $40 no pro rolls a truck; above $500k is a construction
 *  project, not a local quote; a high more than 12x the low is a shrug. */
const MIN_PRICE = 40;
const MAX_PRICE = 500_000;
const MAX_SPREAD = 12;

/** Parses and sanity-checks the model's JSON. Null means "decline". */
export function validateEstimate(text: string | undefined): LLMEstimate | null {
  if (!text) return null;
  let o: { priceable?: unknown; low?: unknown; typical?: unknown; high?: unknown };
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  if (o.priceable !== true) return null;
  const { low, typical, high } = o;
  if (typeof low !== "number" || typeof typical !== "number" || typeof high !== "number") return null;
  if (![low, typical, high].every(Number.isFinite)) return null;
  if (low < MIN_PRICE || high > MAX_PRICE) return null;
  if (!(low <= typical && typical <= high)) return null;
  if (high > low * MAX_SPREAD) return null;
  return { low, typical, high };
}

export function buildUserMessage(input: LLMEstimateInput): string {
  const where = input.zip
    ? `ZIP ${input.zip}${input.state ? `, ${input.state}` : ""}`
    : "United States (no location given; use national averages)";
  return [
    `Request: ${input.description}`,
    input.category ? `Category the user browsed: ${input.category}` : "",
    input.vehicle ? `Vehicle: ${input.vehicle === "moto" ? "motorcycle" : "car"}` : "",
    `Location: ${where}`,
  ].filter(Boolean).join("\n");
}

export async function estimateWithLLM(
  input: LLMEstimateInput,
  apiKey: string,
): Promise<LLMEstimate | null> {
  if (!apiKey || input.description.trim().length < 3) return null;
  const client = new Anthropic({ apiKey, timeout: 20_000, maxRetries: 1 });
  const response = await client.beta.messages.create({
    model: "claude-opus-5",
    max_tokens: 4000,
    // Low effort: a price lookup, not a reasoning task — and the user is
    // waiting on the contractor list header.
    output_config: {
      effort: "low",
      format: { type: "json_schema", schema: SCHEMA },
    },
    // On a safety decline, the API re-runs the request on a fallback model
    // instead of returning an empty turn.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: buildUserMessage(input) }],
  });
  if (response.stop_reason === "refusal" || response.stop_reason === "max_tokens") return null;
  const textBlock = response.content.find((b) => b.type === "text");
  return validateEstimate(textBlock?.type === "text" ? textBlock.text : undefined);
}
