// Supabase Edge Function: `photofit`
//
// The LLM's final check on the results list: for the specific job the user
// described, which of each business's work photos actually show that job, and
// how well each business fits it. Keyword overlap can't make this call — for
// "connect sauna electrical" every electrician's breaker-panel shot shares the
// words "electrical"/"panel", so the list led with panels and threw the user
// off (reported 2026-09-30). The model judges the whole picture instead: the
// job spec from the clarify chat (components, specialties, what a matching
// photo looks like, what merely looks on-trade) against each photo's tags and
// the business's own reviews.
//
// Text-only (tags + review snippets, no images), one call per results list, so
// it is cheap: the vision work already happened once per place in `phototags`.
//
// POST {
//   job: { summary, title, spec?: { complexity, components, trades,
//          specialties, photo_match, photo_reject } },
//   businesses: [{ id, name, photos: [{ url, tags: [string] }], reviews: [string] }]
// }
//   -> { businesses: [{ id, fit: 0-3, relevant: [url], reason }] }
//
// `relevant` lists ONLY photos that show this job or a genuinely similar one —
// an empty list means "show no photos for this business" (a wrong photo is
// worse than none). Failure -> 5xx; the client keeps its keyword ordering.
//
// Deploy:  supabase functions deploy photofit
// Secrets: ANTHROPIC_API_KEY (shared)

import Anthropic from "npm:@anthropic-ai/sdk";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const WORKSPACE_ID = Deno.env.get("ANTHROPIC_WORKSPACE_ID") ?? "";

// Bounds: the list judges its visible window, not the whole pool.
const MAX_BUSINESSES = 15;
const MAX_PHOTOS = 12;
const MAX_TAGS = 16;
const MAX_REVIEWS = 5;
const MAX_REVIEW_CHARS = 280;

const SYSTEM = `You are the final check on a list of local businesses shown to a \
customer for ONE specific job. For each business you get its work photos (as \
tags a vision model produced — the photo itself is not shown to you) and a few \
of its customer reviews. Decide two things:

1. relevant: which photos SHOW THIS JOB or a genuinely similar one — the photo \
a customer would look at and think "they've done what I need". Judge the WHOLE \
job, not its trade: for a sauna electrical hookup, a sauna heater, a hot tub \
or spa disconnect, or a trenched outdoor run is relevant; a breaker-panel \
close-up, a light fixture, an outlet, or a meter bank is NOT — same trade, \
different job, and showing it misleads the customer. For a simple task the \
match is literal: for "replace a breaker" a breaker panel IS the job.
   - Use the spec's photo_match as what a match looks like and photo_reject as \
on-trade photos that do NOT count.
   - A storefront, office, vehicle, logo, team photo, or empty room is never \
relevant.
   - When unsure whether a photo shows this job, leave it OUT. An empty list is \
a correct, expected answer — the business is then shown without photos.

2. fit (0-3): how well this business fits THIS job.
   3 = clear evidence they do this job (relevant photos and/or reviews naming it).
   2 = strong related evidence (adjacent specialty in the spec, e.g. hot tubs \
for a sauna, or reviews about comparable scope).
   1 = right trade, no evidence of this kind of job.
   0 = wrong kind of business for this job.
   reason: one short plain line of the evidence ("reviews mention wiring 2 hot \
tubs"), or "" when fit is 1 or 0. Never invent evidence.

Return every business, in the order given, photos referenced by their number.`;

const SCHEMA = {
  type: "object",
  properties: {
    businesses: {
      type: "array",
      items: {
        type: "object",
        properties: {
          index: { type: "integer" },
          relevant_photos: { type: "array", items: { type: "integer" } },
          fit: { type: "integer", enum: [0, 1, 2, 3] },
          reason: { type: "string" },
        },
        required: ["index", "relevant_photos", "fit", "reason"],
        additionalProperties: false,
      },
    },
  },
  required: ["businesses"],
  additionalProperties: false,
} as const;

interface Photo { url: string; tags: string[] }
interface Business { id: string; name: string; photos: Photo[]; reviews: string[] }

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const str = (v: unknown, max = 400): string =>
  typeof v === "string" ? v.trim().slice(0, max) : "";
const strList = (v: unknown, maxItems: number, maxLen = 80): string[] =>
  Array.isArray(v)
    ? v.map((x) => str(x, maxLen)).filter((x) => x.length > 0).slice(0, maxItems)
    : [];

/** Validate + bound the request into plain data. Exported for tests. */
export function parseBusinesses(raw: unknown): Business[] {
  if (!Array.isArray(raw)) return [];
  const out: Business[] = [];
  for (const b of raw.slice(0, MAX_BUSINESSES)) {
    const o = b as Record<string, unknown>;
    const id = str(o?.id, 200);
    if (!id) continue;
    const photos: Photo[] = [];
    for (const p of Array.isArray(o.photos) ? o.photos : []) {
      const url = str((p as Record<string, unknown>)?.url, 2000);
      if (!url) continue;
      photos.push({ url, tags: strList((p as Record<string, unknown>).tags, MAX_TAGS, 40) });
      if (photos.length >= MAX_PHOTOS) break;
    }
    out.push({
      id,
      name: str(o.name, 120),
      photos,
      reviews: strList(o.reviews, MAX_REVIEWS, MAX_REVIEW_CHARS),
    });
  }
  return out;
}

/** The user message: the job, then each business with numbered photos. */
export function buildPrompt(job: Record<string, unknown>, businesses: Business[]): string {
  const spec = (job.spec ?? {}) as Record<string, unknown>;
  const lines: string[] = ["JOB"];
  const title = str(job.title, 120);
  const summary = str(job.summary, 600);
  if (title) lines.push(`title: ${title}`);
  if (summary) lines.push(`customer's words: ${summary}`);
  const specLine = (k: string, label: string) => {
    const v = strList(spec[k], 10);
    if (v.length) lines.push(`${label}: ${v.join("; ")}`);
  };
  const complexity = str(spec.complexity, 20);
  if (complexity) lines.push(`complexity: ${complexity}`);
  specLine("components", "components");
  specLine("trades", "trades");
  specLine("specialties", "strong-fit specialties");
  specLine("photo_match", "photo_match");
  specLine("photo_reject", "photo_reject");
  lines.push("", "BUSINESSES");
  businesses.forEach((b, i) => {
    lines.push(`[${i}] ${b.name || "business"}`);
    if (b.photos.length === 0) lines.push("  photos: none");
    b.photos.forEach((p, j) => lines.push(`  photo ${j}: ${p.tags.join(", ") || "(no tags)"}`));
    b.reviews.forEach((r) => lines.push(`  review: "${r.replace(/\s+/g, " ")}"`));
  });
  return lines.join("\n");
}

/** Map the model's indexed answer back onto ids + urls. Anything malformed or
 *  out of range is dropped; a business the model skipped is simply absent, and
 *  the client keeps its own ordering for it. Exported for tests. */
export function mapVerdicts(text: string, businesses: Business[]) {
  const parsed = JSON.parse(text) as { businesses?: unknown };
  const rows = Array.isArray(parsed.businesses) ? parsed.businesses : [];
  const out: Array<{ id: string; fit: number; relevant: string[]; reason: string }> = [];
  const seen = new Set<number>();
  for (const r of rows) {
    const o = r as Record<string, unknown>;
    const i = o.index;
    if (typeof i !== "number" || !Number.isInteger(i) || i < 0 || i >= businesses.length || seen.has(i)) continue;
    seen.add(i);
    const b = businesses[i];
    const idx = Array.isArray(o.relevant_photos) ? o.relevant_photos : [];
    const relevant = [...new Set(idx)]
      .filter((j): j is number => typeof j === "number" && Number.isInteger(j) && j >= 0 && j < b.photos.length)
      .map((j) => b.photos[j].url);
    const fit = typeof o.fit === "number" && o.fit >= 0 && o.fit <= 3 ? Math.round(o.fit) : 1;
    out.push({ id: b.id, fit, relevant, reason: fit >= 2 ? str(o.reason, 160) : "" });
  }
  return out;
}

if (import.meta.main) {
  Deno.serve(async (req) => {
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
    if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
      return json({ error: "unauthorized" }, 401);
    }
    if (!ANTHROPIC_API_KEY) return json({ error: "photofit unavailable" }, 503);

    let payload: Record<string, unknown>;
    try {
      payload = await req.json();
    } catch {
      return json({ error: "invalid json body" }, 400);
    }
    const job = (payload.job ?? {}) as Record<string, unknown>;
    const businesses = parseBusinesses(payload.businesses);
    if (businesses.length === 0) return json({ businesses: [] });
    if (!str(job.summary) && !str(job.title)) return json({ error: "missing job" }, 400);

    try {
      const client = new Anthropic({
        apiKey: ANTHROPIC_API_KEY,
        timeout: 15_000,
        maxRetries: 0,
        ...(WORKSPACE_ID ? { defaultHeaders: { "anthropic-workspace-id": WORKSPACE_ID } } : {}),
      });
      const response = await client.messages.create({
        model: "claude-sonnet-5",
        max_tokens: 1500,
        thinking: { type: "disabled" },
        system: [{ type: "text", text: SYSTEM, cache_control: { type: "ephemeral" } }],
        output_config: { format: { type: "json_schema", schema: SCHEMA } },
        messages: [{ role: "user", content: buildPrompt(job, businesses) }],
      });
      const text = response.content.find((b) => b.type === "text")?.text ?? "";
      const verdicts = mapVerdicts(text, businesses);
      console.log("photofit", JSON.stringify({
        job: str(job.title, 80),
        n: businesses.length,
        kept: verdicts.reduce((a, v) => a + v.relevant.length, 0),
        total: businesses.reduce((a, b) => a + b.photos.length, 0),
      }));
      return json({ businesses: verdicts });
    } catch (err) {
      console.error("photofit: model call failed", err);
      return json({ error: "photofit failed" }, 502);
    }
  });
}
