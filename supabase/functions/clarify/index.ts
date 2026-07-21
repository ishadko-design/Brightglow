// Supabase Edge Function: `clarify`
//
// The clarifying chat that runs between the user's typed/photographed request
// and the results screen. Its PRIMARY job is to disambiguate toward the right
// LOCAL BUSINESS — a home-trade contractor or an auto/moto shop — and to
// describe what a matching work photo looks like so results can rank businesses
// that have actually done a similar job. A price estimate is a SECONDARY bonus,
// produced only for home trades the pricing engine covers.
//
// The chat never produces a price itself — the client feeds `details` into the
// `pricing` function. Any failure here is non-fatal: the client proceeds to the
// results screen exactly as if the chat hadn't run.
//
// Scalable questioning: there is no fixed question count. The model asks only
// questions whose answer changes the business match, the photo filter, or the
// price, and stops the instant the match is confident — 1 question for a clear
// job, up to HARD_CEILING for an ambiguous multi-service one.
//
// POST { messages: [{role: "user"|"assistant", content}], photo_details? }
//   -> { action: "ask",  question, quick_replies, vertical, category }
//   -> { action: "done", vertical, category, search_terms, photo_terms,
//                        details, summary, priceable }
//
// Deploy:   supabase functions deploy clarify
// Secrets:  ANTHROPIC_API_KEY (shared with `pricing`; unset -> 503, client
//           skips the chat and goes straight to results)

import Anthropic from "npm:@anthropic-ai/sdk";
import { CATEGORY_GENERAL, JOB_TYPE_TAXONOMY } from "../pricing/pricingEngine.ts";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

// Safety ceiling only — NOT a target. The model is told to stop as soon as the
// match is confident; most requests finish in 1-3 questions.
const HARD_CEILING = 7;

// Home-trade categories the pricing engine knows (drives `priceable`).
const HOME_CATEGORIES = [...new Set(JOB_TYPE_TAXONOMY.map((e) => e.category))];

// Auto & moto services — must mirror `autoCategoryItems` in Brightglow's
// Vertical.swift. No pricing data source exists for vehicle work, so these are
// never `priceable`; the chat's whole value here is match + photo terms.
const AUTO_SERVICES = ["Repair", "Tires", "Cleaning & Detailing", "Body & Paint", "Glass"];

const ALL_CATEGORIES = [...HOME_CATEGORIES, ...AUTO_SERVICES];

// What the pricing engine can actually use — shown to the model so its home
// questions target price-relevant gaps and its `details` land in parseable units.
const TAXONOMY_LINES = [
  ...JOB_TYPE_TAXONOMY.map((e) => `- ${e.job_type} (${e.category}, per ${e.unit})`),
  ...Object.values(CATEGORY_GENERAL)
    .filter((e) => e !== null)
    .map((e) => `- ${e!.job_type} (${e!.category}, per ${e!.unit} — generic fallback)`),
].join("\n");

function systemPrompt(remaining: number): string {
  const mustFinish = remaining === 0;
  return `You help a user find a LOCAL BUSINESS that can fix their problem — \
either a home-trade contractor or an auto/moto shop. Your job is to ask the \
fewest questions needed to (1) identify the right kind of business and (2) \
describe what a matching work photo looks like. A price is a bonus, never the goal.

You may ask at most ${remaining} more question${remaining === 1 ? "" : "s"}\
${mustFinish ? ' — you MUST finish now with action "done"' : ""}.

Ask a question (action "ask") ONLY if its answer changes one of:
- which KIND of business matches (the biggest lever, ask this first),
- which of a business's work photos count as "a similar job",
- the price (home trades only).
Stop the moment you can confidently name the business type and the matching
photo — that may be after a single question. Keep asking (up to the limit) only
while the request still straddles clearly different businesses or services.
Never pad to the limit with low-value questions.

Question style: one per turn, plain non-technical language, under 20 words,
2-4 short quick_replies when natural options exist. Never ask for contact info,
address, or timing.

TRUST THE PHOTO: when the request carries a "(Visible in the user's photo: …)"
note, treat every attribute it states as ALREADY ESTABLISHED and never ask what
it answers. If it names a car, truck, or motorcycle (or any make/model), the
vehicle type is settled — do NOT ask car-vs-motorcycle. If it names the make,
model, material, size, or capacity, do not re-ask those. Fold a known make/model
into search_terms and photo_terms (e.g. "silver Honda Civic bumper").

Decide the VERTICAL first:
- "home" — repair/improvement to a house or yard: ${HOME_CATEGORIES.join(", ")}.
- "auto_moto" — anything about a car, truck, or motorcycle. Services:
  Repair (engine, brakes, transmission, oil, general maintenance), Tires,
  Cleaning & Detailing, Body & Paint (dents, scratches, collision, respray),
  Glass (windshield, auto glass). If it's a MOTORCYCLE, always establish that —
  it routes to motorcycle shops, not car shops.

Per-vertical priorities:
- Auto/moto: ask car-vs-motorcycle ONLY when neither the request nor the photo
  note reveals it — if the photo already names the vehicle, skip straight to
  matching. If the problem straddles services (e.g. "fix my bumper" could be
  Body & Paint or a dealer), ask which. No price is produced — do not ask
  price-only questions. Once the service and vehicle are known, finish.
- Home: after the business type is clear, ask the cost driver that also sharpens
  the photo match — the item's material/type and (for per-area jobs) size.
  For size-driven work (windows, flooring, painting, roofing) ALWAYS pin the
  dimensions — they swing the price several-fold. Read what the photo already
  shows (a wide slider vs. a small casement, one window vs. a wall of them) and
  confirm the numbers with the user; ask, don't guess a measurement.
  Examples: furnace -> gas / heat pump / mini split; water heater -> tank /
  tankless; window -> operation (sliding, casement, double-hung), frame material
  (vinyl, wood, aluminum, fiberglass), SCOPE (just the glass/a foggy or broken
  pane vs. the whole window incl. frame vs. a full-frame tear-out), and
  approximate size (W×H) and how many; flooring -> material + area + whether the
  old floor is removed; roof -> material + approx area; vanity -> width +
  whether faucet/top are replaced.

Finishing (action "done") — fill EVERY field:
- vertical: "home" | "auto_moto".
- category: the best-fit business category. Home: one of ${HOME_CATEGORIES.join(", ")}. \
Auto: one of ${AUTO_SERVICES.join(", ")}. Use "" only if nothing fits.
- search_terms: a short Google-Maps-style phrase to FIND the business, e.g.
  "tankless water heater installer", "motorcycle brake repair shop",
  "auto body dent repair", "hardwood flooring contractor". Include the vehicle
  type for auto. Keep it to the trade/service — no location, no brand.
- photo_terms: 2-6 words describing what a matching WORK PHOTO shows, used to
  rank each business's photos. E.g. "tankless water heater wall", "motorcycle
  brake caliper disc", "dented car bumper", "hardwood floor living room".
- details: HOME ONLY — a short comma-separated summary of the cost-relevant
  facts the user confirmed, phrased canonically so the pricing engine can parse
  them: areas as "N sq ft", lengths as "N linear ft", counts as "N windows" /
  "N doors" / "N outlets", vanity widths as "N inch vanity", window/door
  dimensions as "WxH window" / "WxH door" in inches (e.g. "72x80 window"), roof
  materials as "asphalt shingle roof" / "metal roof", french doors as
  "N pair(s) of french doors", scope as "remove old flooring" / "subfloor repair"
  / "keep existing faucet". For an opening, state the replacement scope in these
  exact words so it prices right: "glass only" (just the pane/foggy seal),
  "full frame replacement" (tear out to the rough opening), or nothing for a
  standard insert. Only facts the user explicitly stated or confirmed — never guess.
  Use "" for auto/moto, or if no cost fact was pinned down.
- summary: a plain-English overview of the job for the BUSINESS to read at a
  glance — 1-2 short sentences that fold the user's request together with the
  facts they confirmed in the chat, in natural prose. Write it as a human intake
  note, not a transcript: no "Q:"/"A:", no bullets, no "the customer said". Fold
  in only what was actually established (from the request, the photo note, or the
  answers). Example: "Exterior repaint of a backyard fence, plus planting new
  shrubs along the yard." Never invent scope, timing, or budget. Use "" if the
  request was too vague to describe.

When asking (action "ask"): also return your best-so-far vertical and category
(use "" if not yet known); leave search_terms, photo_terms, details, summary as "".

The pricing engine covers these home jobs — for home requests, aim toward them
and note each one's pricing unit (the quantity worth clarifying):
${TAXONOMY_LINES}`;
}

const SCHEMA = {
  type: "object",
  properties: {
    action: { type: "string", enum: ["ask", "done"] },
    question: { type: "string" },
    quick_replies: { type: "array", items: { type: "string" } },
    vertical: { type: "string", enum: ["home", "auto_moto", ""] },
    category: { type: "string", enum: [...ALL_CATEGORIES, ""] },
    search_terms: { type: "string" },
    photo_terms: { type: "string" },
    details: { type: "string" },
    summary: { type: "string" },
  },
  required: [
    "action", "question", "quick_replies",
    "vertical", "category", "search_terms", "photo_terms", "details", "summary",
  ],
  additionalProperties: false,
} as const;

interface Turn {
  role: "user" | "assistant";
  content: string;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/// A price is only ever expected for a covered home trade. Auto/moto and any
/// category the pricing engine doesn't know are match-only.
function isPriceable(vertical: string, category: string): boolean {
  return vertical === "home" && HOME_CATEGORIES.includes(category);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!ANTHROPIC_API_KEY) return json({ error: "clarify unavailable" }, 503);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const rawMessages = payload.messages;
  if (!Array.isArray(rawMessages) || rawMessages.length === 0 || rawMessages.length > 40) {
    return json({ error: "missing messages" }, 400);
  }
  const messages: Turn[] = [];
  for (const m of rawMessages) {
    const role = (m as Turn)?.role;
    const content = (m as Turn)?.content;
    if ((role !== "user" && role !== "assistant") || typeof content !== "string" || !content.trim()) {
      return json({ error: "invalid message" }, 400);
    }
    messages.push({ role, content: content.slice(0, 2000) });
  }

  const photoDetails = typeof payload.photo_details === "string" ? payload.photo_details : "";
  if (photoDetails) {
    messages[0] = {
      role: messages[0].role,
      content: `${messages[0].content}\n(Visible in the user's photo: ${photoDetails})`,
    };
  }

  const asked = messages.filter((m) => m.role === "assistant").length;
  const remaining = Math.max(0, HARD_CEILING - asked);

  let parsed: {
    action?: string;
    question?: string;
    quick_replies?: string[];
    vertical?: string;
    category?: string;
    search_terms?: string;
    photo_terms?: string;
    details?: string;
    summary?: string;
  };
  try {
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: 20_000, maxRetries: 1 });
    const response = await client.messages.create({
      // Sonnet is markedly faster than Opus for this lightweight per-turn routing
      // task and just as accurate against the fixed schema — the chat felt slow.
      model: "claude-sonnet-5",
      max_tokens: 600,
      // Sonnet 5 runs adaptive thinking when `thinking` is omitted — we don't
      // want it here: this is a quick schema-bound routing call, and thinking
      // only adds latency and output-token cost. Keep it off for speed.
      thinking: { type: "disabled" },
      system: systemPrompt(remaining),
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages,
    });
    const text = response.content.find((b) => b.type === "text")?.text ?? "";
    parsed = JSON.parse(text);
  } catch (err) {
    console.error("clarify: model call failed", err);
    return json({ error: "clarify failed" }, 502);
  }

  // Out of questions -> the model was told to finish; coerce if it didn't. We
  // keep whatever match fields it produced so results still get search terms.
  if (parsed.action !== "done" && remaining === 0) {
    parsed.action = "done";
  }

  if (parsed.action === "ask" && parsed.question) {
    return json({
      action: "ask",
      question: parsed.question,
      quick_replies: (parsed.quick_replies ?? []).slice(0, 4),
      vertical: parsed.vertical ?? "",
      category: parsed.category ?? "",
    });
  }

  const vertical = parsed.vertical === "auto_moto" ? "auto_moto" : "home";
  const category = parsed.category ?? "";
  return json({
    action: "done",
    vertical,
    category,
    search_terms: parsed.search_terms ?? "",
    photo_terms: parsed.photo_terms ?? "",
    details: vertical === "home" ? (parsed.details ?? "") : "",
    summary: parsed.summary ?? "",
    priceable: isPriceable(vertical, category),
  });
});
