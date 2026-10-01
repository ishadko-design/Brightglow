// Business-type gate for the `search` function.
//
// Google Text Search ranks by words, so a clarified job can still pull in the
// wrong KIND of business — "Install outdoor sauna" surfaced a sauna & hot-tub
// RETAILER's showroom first when the homeowner needs an electrician (on-device
// test 2026-09-30). One wrong business costs the user's trust in every result,
// so before any place reaches the app, an LLM answers one question per place:
// would a homeowner hire THIS business to do THIS work (or a required part of
// it)? From the place's name, Google types, website domain and review snippets.
//
// Text-only, parallel chunks (latency ~ output length), Sonnet 5. Verdicts are
// memoized per isolate by (job, place) so "See more" and repeat searches don't
// re-ask. Any failure returns null and the caller passes results through.

import Anthropic from "npm:@anthropic-ai/sdk";

export interface GateJob {
  title?: string;
  summary?: string;
  spec?: {
    complexity?: string;
    components?: string[];
    trades?: string[];
    specialties?: string[];
  };
}

const CHUNK = 7;
const MAX_REVIEWS = 3;
const MAX_REVIEW_CHARS = 220;
const memo = new Map<string, boolean>();
const MEMO_MAX = 5000;

const SYSTEM = `You screen local businesses for ONE homeowner job. For each \
business answer keep=true only if a homeowner would HIRE this business to do \
this work, or a required part of it (one of the job's listed trades).

keep=false for:
- stores, showrooms, dealers, distributors and manufacturers that SELL the \
product (a sauna or hot tub retailer, a lighting store, a supply house) — \
unless its reviews clearly show its own crew doing this installation work;
- a different trade (a plumber for wiring, a pool cleaner for an electrical \
hookup, a landscaper for a panel);
- maintenance/cleaning/service-only outfits when the job is an installation, \
and vice versa when the reviews make that plain;
- anything that is not a contractor/service business at all.

keep=true for a business of a listed trade even with no evidence of this exact \
job (ranking handles evidence) — only drop on a clear mismatch of business \
KIND. A general contractor or handyman stays only when the job is within its \
normal scope (a handyman is fine for a small repair, not for a permitted \
240V circuit). When genuinely unsure, keep.

Return every business in the order given.`;

const SCHEMA = {
  type: "object",
  properties: {
    keep: { type: "array", items: { type: "boolean" } },
  },
  required: ["keep"],
  additionalProperties: false,
} as const;

const s = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");
const list = (v: unknown) =>
  Array.isArray(v) ? v.map((x) => s(x, 80)).filter(Boolean).slice(0, 8) : [];

export function jobKey(job: GateJob): string {
  const spec = job.spec ?? {};
  return [s(job.title, 120), list(spec.trades).join(","), s(spec.complexity, 20)]
    .join("|").toLowerCase();
}

export function describeJob(job: GateJob): string {
  const spec = job.spec ?? {};
  const lines = ["JOB"];
  if (s(job.title, 120)) lines.push(`title: ${s(job.title, 120)}`);
  if (s(job.summary, 500)) lines.push(`customer's words: ${s(job.summary, 500)}`);
  if (s(spec.complexity, 20)) lines.push(`complexity: ${s(spec.complexity, 20)}`);
  if (list(spec.trades).length) lines.push(`trades that do it: ${list(spec.trades).join("; ")}`);
  if (list(spec.components).length) lines.push(`components: ${list(spec.components).join("; ")}`);
  if (list(spec.specialties).length) lines.push(`strong-fit specialties: ${list(spec.specialties).join("; ")}`);
  return lines.join("\n");
}

export function describePlace(p: Record<string, unknown>, i: number): string {
  const name = s((p.displayName as { text?: string } | undefined)?.text, 120) || "business";
  const types = Array.isArray(p.types) ? (p.types as string[]).slice(0, 8).join(", ") : "";
  let site = "";
  try { site = p.websiteUri ? new URL(String(p.websiteUri)).hostname : ""; } catch { /* ignore */ }
  const reviews = (Array.isArray(p.reviews) ? p.reviews : [])
    .slice(0, MAX_REVIEWS)
    .map((r) => s((r as { text?: { text?: string } })?.text?.text, MAX_REVIEW_CHARS).replace(/\s+/g, " "))
    .filter(Boolean);
  const out = [`[${i}] ${name}`];
  if (types) out.push(`  google types: ${types}`);
  if (site) out.push(`  website: ${site}`);
  for (const r of reviews) out.push(`  review: "${r}"`);
  return out.join("\n");
}

/** Ids of places to KEEP, or null when the gate couldn't run (caller passes
 *  everything through). */
export async function gatePlaces(
  job: GateJob,
  places: Array<Record<string, unknown>>,
  apiKey: string,
): Promise<Set<string> | null> {
  if (!s(job.title, 120) && !s(job.summary, 500)) return null;
  const jk = jobKey(job);
  const keep = new Set<string>();
  const todo: Array<Record<string, unknown>> = [];
  for (const p of places) {
    const id = String(p.id ?? "");
    if (!id) continue;
    const m = memo.get(`${jk}|${id}`);
    if (m === undefined) todo.push(p);
    else if (m) keep.add(id);
  }
  if (todo.length === 0) return keep;

  const workspaceId = Deno.env.get("ANTHROPIC_WORKSPACE_ID") ?? "";
  const client = new Anthropic({
    apiKey,
    timeout: 8_000,
    maxRetries: 0,
    ...(workspaceId ? { defaultHeaders: { "anthropic-workspace-id": workspaceId } } : {}),
  });
  const jobText = describeJob(job);
  const chunks: Array<Array<Record<string, unknown>>> = [];
  for (let i = 0; i < todo.length; i += CHUNK) chunks.push(todo.slice(i, i + CHUNK));

  const settled = await Promise.allSettled(chunks.map(async (chunk) => {
    const r = await client.messages.create({
      model: "claude-sonnet-5",
      max_tokens: 200,
      thinking: { type: "disabled" },
      system: [{ type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } }],
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: [{
        role: "user",
        content: `${jobText}\n\nBUSINESSES\n${chunk.map(describePlace).join("\n")}`,
      }],
    });
    const text = r.content.find((b) => b.type === "text")?.text ?? "";
    const arr = (JSON.parse(text) as { keep?: unknown }).keep;
    if (!Array.isArray(arr) || arr.length !== chunk.length) throw new Error("gate: length mismatch");
    return chunk.map((p, i) => [String(p.id), arr[i] !== false] as const);
  }));

  let anyOk = false;
  settled.forEach((r, ci) => {
    if (r.status === "fulfilled") {
      anyOk = true;
      for (const [id, k] of r.value) {
        if (memo.size > MEMO_MAX) memo.clear();
        memo.set(`${jk}|${id}`, k);
        if (k) keep.add(id);
      }
    } else {
      // A failed chunk keeps its places (fail open per chunk).
      console.error("search: gate chunk failed", String(r.reason).slice(0, 200));
      for (const p of chunks[ci]) keep.add(String(p.id));
    }
  });
  return anyOk ? keep : null;
}
