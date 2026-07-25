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
import {
  AUTO_CATEGORIES,
  CATEGORY_GENERAL,
  COUNTABLE_NOUNS,
  JOB_TYPE_TAXONOMY,
} from "../pricing/pricingEngine.ts";
import { GENERIC_REPLIES, normalizeQuickReplies } from "./quickReplies.ts";
import { repeatsPriorQuestion } from "./repeatsPriorQuestion.ts";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

// Safety ceiling only — NOT a target. The model is told to stop as soon as the
// match is confident; most requests finish in 1-3 questions.
const HARD_CEILING = 7;

// Home-trade categories the pricing engine knows (drives `priceable`). The
// taxonomy holds BOTH verticals, so the auto services have to be subtracted —
// without that, this list offered the model "Repair" as a home category and
// `isPriceable("home", "Repair")` answered true.
const HOME_CATEGORIES = [...new Set(JOB_TYPE_TAXONOMY.map((e) => e.category))]
  .filter((c) => !AUTO_CATEGORIES.has(c));

// Auto & moto services — must mirror `autoCategoryItems` in Brightglow's
// Vertical.swift. Priced since 2026-07-20, same as the home trades.
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

NEVER re-ask something already answered. Before asking, read the whole
conversation above: if the user has already given a size, a material, a count,
a vehicle type, or any fact — even approximately ("200-300 sq ft", "a sedan") —
treat it as SETTLED and move on. Re-asking the same question the user just
answered (e.g. asking garage-floor size twice) is a bug users notice
immediately. If their answer was a range or was vague, that is still an answer —
accept it, do not ask again for a sharper number.

Question style: one per turn, plain non-technical language, under 20 words.
Never ask for contact info, address, or timing.

EVERY question MUST ship with 2-4 quick_replies. This is not optional and an
empty list is never acceptable — tapping is the whole interaction on a phone,
and a question with no options strands the user at a keyboard.
- Either/or question? The options ARE the alternatives you just named. Asking
  "is it inside the house, or the main line to the street?" and returning no
  options is the exact failure this rule exists to stop (reported 2026-07-22).
- Quantity or size? Offer representative values ("Under 20 ft", "20-50 ft",
  "Over 50 ft"), not an open prompt.
- Genuinely open ("describe the noise")? Then rephrase it as a choice, or offer
  the likeliest answers plus "Something else".
Add "Not sure" as the last option whenever a homeowner plausibly wouldn't know.
Keep each label under 4 words so it fits a chip.

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
  Body & Paint or a dealer), ask which. For a WRAP, a DETAIL, a CERAMIC COATING
  or a full/panel RESPRAY, the vehicle's SIZE swings the price, so ask "What
  kind of vehicle — car, SUV, or truck?" unless the request or photo already
  says; put the answer in details as one of "compact sedan", "SUV", or
  "full-size vehicle". For mechanical repairs (brakes, alternator, oil) size
  doesn't matter — don't ask. Once service and vehicle are known, finish.
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
  whether faucet/top are replaced; recessed lighting -> how many, AND whether
  there is already a light there or it's a brand-new spot (that doubles the
  per-light price).

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
  them: areas as "N sq ft", lengths as "N linear ft", counts as "N <thing>"
  where <thing> is one of: ${COUNTABLE_NOUNS.join(", ")} (these are the ONLY
  nouns the engine can count — a count of anything else is dropped silently, so
  don't spend a question on it), vanity widths as "N inch vanity", window/door
  dimensions as "WxH window" / "WxH door" in inches (e.g. "72x80 window"), roof
  materials as "asphalt shingle roof" / "metal roof", french doors as
  "N pair(s) of french doors", scope as "remove old flooring" / "subfloor repair"
  / "keep existing faucet". For an opening, state the replacement scope in these
  exact words so it prices right: "glass only" (just the pane/foggy seal),
  "full frame replacement" (tear out to the rough opening), or nothing for a
  standard insert. For RECESSED / can lighting, the price turns on whether a
  light is already there: write "no existing light there" for a brand-new spot
  (new hole, wire fishing, ceiling patch — about 2x), or nothing for a swap or
  a spot with power already present. Do NOT write "new circuit" for this — that
  phrase means a different job. Write every measurement as ONE number, never a range: the
  engine reads the last number it sees, so "100-300 sq ft" silently prices the
  top end. If the user answered with a range, record its midpoint ("200 sq ft").
  Only facts the user explicitly stated or confirmed — never guess.
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
    // NB: no minItems/maxItems here. They look like the obvious fix for the
    // empty-chips bug, but the structured-output API rejects the schema
    // outright with them present and every turn 502s (caught 2026-07-22 before
    // it reached anyone). The guarantee lives in the prompt and in the retry
    // in retryQuickReplies instead.
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

/// Whether the results screen should attempt a price — it skips the pricing
/// request entirely when this is false, so a wrong `false` here is silent.
///
/// Auto & moto used to be excluded on the grounds that no cost data existed for
/// vehicle work. That stopped being true on 2026-07-20, when the catalog gained
/// ~40 auto/moto items with published anchors and all five categories got a
/// general entry — but this function was never updated, so every car job the
/// engine could price came back match-only and the number was thrown away
/// before it was ever requested (reported 2026-07-22: "no price for any of the
/// car jobs", including wraps, which price at $2.2–7k).
function isPriceable(vertical: string, category: string): boolean {
  return vertical === "auto_moto"
    ? AUTO_CATEGORIES.has(category)
    : HOME_CATEGORIES.includes(category);
}

/** Ask the model for options for a question it already produced without them.
 *  Falls back to a generic tappable set if this call also comes up short —
 *  never returns fewer than two, since one option is as much a dead end as
 *  none. Never throws: chips are an enhancement, not a reason to fail the turn. */
async function retryQuickReplies(question: string): Promise<string[]> {
  try {
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: 8_000, maxRetries: 0 });
    const r = await client.messages.create({
      model: "claude-sonnet-5",
      max_tokens: 150,
      thinking: { type: "disabled" },
      system:
        'Return 2-4 short tappable answer options for the question, as JSON ' +
        '{"quick_replies":["..."]}. For an either/or question the options are ' +
        'the alternatives it names. Each label under 4 words, no punctuation. ' +
        'Add "Not sure" last when someone plausibly would not know.',
      output_config: {
        format: {
          type: "json_schema",
          schema: {
            type: "object",
            properties: {
              quick_replies: { type: "array", items: { type: "string" } },
            },
            required: ["quick_replies"],
            additionalProperties: false,
          },
        },
      },
      messages: [{ role: "user", content: question }],
    });
    const text = r.content.find((b) => b.type === "text")?.text ?? "";
    const { replies, usable } = normalizeQuickReplies(JSON.parse(text).quick_replies);
    if (usable) return replies;
  } catch (err) {
    console.error("clarify: quick-reply retry failed", err);
  }
  return GENERIC_REPLIES;
}

/** Extract just a vehicle-size phrase from the model's auto details, dropping
 *  everything else. Auto details are otherwise blank (the pricing engine reads
 *  vehicle type from a structured field, not free text), but vehicle SIZE has
 *  no structured field and is a real price lever for wraps, detailing and
 *  paint. Whitelisted, not free-text, so nothing else rides into the auto path.
 *  Kept in sync with vehicleSizeScale in inHouseEngine.ts. */
function vehicleSizeToken(details: string): string {
  const t = details.toLowerCase();
  if (/\b(full[- ]?size|dually|lifted|3500|2500|f-?250|f-?350|sprinter|box truck|cargo van|suburban|expedition|tahoe)\b/.test(t)) return "full-size vehicle";
  if (/\b(suv|truck|pickup|van|minivan|jeep|crossover|silverado|f-?150|ram|tacoma|4runner)\b/.test(t)) return "SUV";
  if (/\b(compact|subcompact|sedan|coupe|hatchback|small car|two[- ]door|miata|civic|corolla)\b/.test(t)) return "compact sedan";
  return "";
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
  // Sonnet is markedly faster than Opus for this lightweight per-turn routing
  // task and just as accurate against the fixed schema. `mustFinish` forces the
  // "you MUST finish now" prompt, used to recover a proper `done` (with all the
  // match/detail fields) when the model tries to re-ask an answered question.
  const runModel = async (mustFinish: boolean) => {
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: 20_000, maxRetries: 1 });
    const response = await client.messages.create({
      model: "claude-sonnet-5",
      max_tokens: 600,
      // Sonnet 5 runs adaptive thinking when `thinking` is omitted — off here:
      // a quick schema-bound routing call, thinking only adds latency and cost.
      thinking: { type: "disabled" },
      system: systemPrompt(mustFinish ? 0 : remaining),
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages,
    });
    const text = response.content.find((b) => b.type === "text")?.text ?? "";
    return JSON.parse(text);
  };

  try {
    parsed = await runModel(false);
  } catch (err) {
    console.error("clarify: model call failed", err);
    return json({ error: "clarify failed" }, 502);
  }

  // Out of questions -> the model was told to finish; coerce if it didn't. We
  // keep whatever match fields it produced so results still get search terms.
  if (parsed.action !== "done" && remaining === 0) {
    parsed.action = "done";
  }

  // Duplicate-question guard. The prompt tells the model never to re-ask an
  // answered question, but it does so inconsistently — "About how big is the
  // garage floor?" asked twice after the user answered "200-300 sq ft"
  // (reported 2026-07-23). A range answer seems to trip it: the model wants a
  // sharper number and asks again. Prompt alone can't be trusted here, so this
  // is the deterministic backstop: if the new question substantially repeats one
  // already asked, the user has answered everything this model knows to ask —
  // finish rather than loop.
  if (parsed.action === "ask" && parsed.question && repeatsPriorQuestion(parsed.question, messages)) {
    console.log("clarify: duplicate question suppressed", JSON.stringify({ question: parsed.question }));
    // Re-run forcing a finish, so `done` comes back with the match and detail
    // fields populated — coercing the re-ask to done here would drop the size
    // the user just gave, and the price would lose it. If the retry also fails
    // or somehow re-asks, fall back to a bare done rather than looping.
    try {
      const finished = await runModel(true);
      parsed = finished?.action === "done" ? finished : { ...parsed, action: "done" };
    } catch (err) {
      console.error("clarify: finish retry failed", err);
      parsed.action = "done";
    }
  }

  if (parsed.action === "ask" && parsed.question) {
    // Last line of defence for the empty-chips bug. The prompt demands options,
    // but nothing enforces that, and a question with nothing to tap is a dead
    // end on a phone.
    //
    // Recovery is a second, narrowly-scoped model call rather than splitting the
    // question's own "A, or B?" with a regex: that produces mid-phrase labels
    // ("This pipe inside the") which look broken. This path is rare, so the
    // extra ~1s is paid almost never.
    let { replies, usable } = normalizeQuickReplies(parsed.quick_replies);
    if (!usable) {
      console.log("clarify: empty quick_replies", JSON.stringify({ question: parsed.question }));
      replies = await retryQuickReplies(parsed.question);
    }
    return json({
      action: "ask",
      question: parsed.question,
      quick_replies: replies,
      vertical: parsed.vertical ?? "",
      category: parsed.category ?? "",
    });
  }

  const vertical = parsed.vertical === "auto_moto" ? "auto_moto" : "home";
  // A category from the OTHER vertical is incoherent, and the client reads the
  // vertical off the category name — so "home" + "Repair" opened a car-shop
  // list for a fridge repair (2026-07-22). Drop the category rather than the
  // vertical: the vertical is the model's explicit answer to a direct question,
  // while the category is a best-fit pick from a list that may not contain the
  // right slot. An empty category still searches on `search_terms`.
  const claimed = parsed.category ?? "";
  const coherent = claimed === "" ||
    (vertical === "auto_moto") === AUTO_CATEGORIES.has(claimed);
  if (!coherent) {
    console.log("clarify: cross-vertical category dropped", JSON.stringify({ vertical, category: claimed }));
  }
  const category = coherent ? claimed : "";
  return json({
    action: "done",
    vertical,
    category,
    search_terms: parsed.search_terms ?? "",
    photo_terms: parsed.photo_terms ?? "",
    // Home carries full canonical details. Auto used to carry none — but
    // vehicle SIZE is a real price lever for wraps, detailing and paint (an
    // F-250 wrap is not a Miata wrap), so a size phrase is now allowed through.
    // Restricted to a size token so no free-text leaks into the auto path.
    details: vertical === "home"
      ? (parsed.details ?? "")
      : vehicleSizeToken(parsed.details ?? ""),
    summary: parsed.summary ?? "",
    priceable: isPriceable(vertical, category),
  });
});
