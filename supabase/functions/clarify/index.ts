// Supabase Edge Function: `clarify`
//
// One turn of the clarifying chat that runs between the user's typed request
// and the price estimate. Claude either asks the next question (max 3 per
// session, one at a time, only about things that change the price — quantity,
// size, item type, material) or finishes with a canonical `details` summary
// phrased so the pricing engine's quantity parser can read it ("250 sq ft",
// "2 windows", "2 pairs of french doors"), plus the best-fitting category.
//
// The chat never produces a price — the client feeds `details` into the
// existing `pricing` function, so every displayed number still comes from
// EstimationPro data. Any failure here is non-fatal: the client proceeds to
// the estimate exactly as if the chat didn't exist.
//
// POST { messages: [{role: "user"|"assistant", content}], photo_details? }
//   -> { action: "ask", question, quick_replies }
//   -> { action: "done", category, details }
//
// Deploy:   supabase functions deploy clarify
// Secrets:  ANTHROPIC_API_KEY (shared with `pricing`; unset -> 503, client
//           skips the chat and estimates directly)

import Anthropic from "npm:@anthropic-ai/sdk";
import { CATEGORY_GENERAL, JOB_TYPE_TAXONOMY } from "../pricing/pricingEngine.ts";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

const MAX_QUESTIONS = 3;

const CATEGORIES = [...new Set(JOB_TYPE_TAXONOMY.map((e) => e.category))];

// What the pricing engine can actually use — shown to the model so its
// questions target only price-relevant gaps, and its `details` land on
// covered jobs in parseable units.
const TAXONOMY_LINES = [
  ...JOB_TYPE_TAXONOMY.map((e) => `- ${e.job_type} (${e.category}, per ${e.unit})`),
  ...Object.values(CATEGORY_GENERAL)
    .filter((e) => e !== null)
    .map((e) => `- ${e!.job_type} (${e!.category}, per ${e!.unit} — generic fallback)`),
].join("\n");

function systemPrompt(remaining: number): string {
  return `You help price a home repair or improvement job. Ask the fewest \
clarifying questions needed to pin down what drives the price, then finish. \
You may ask at most ${remaining} more question${remaining === 1 ? "" : "s"}\
${remaining === 0 ? ' — you MUST finish now with action "done"' : ""}.

Rules for questions (action "ask"):
- One question per turn, plain non-technical language, under 20 words.
- Only ask what changes the estimate: quantity or size, the specific item or
  job, material/type. Never ask for contact info, address, or timing.
- Offer 2-4 short quick_replies when natural options exist ("1 pair" /
  "2 pairs", "Vinyl" / "Wood").
- Prefer one good question over finishing early: if the quantity, size, or
  specific item is missing OR could be read more than one way, ask. Example:
  "replace 2 french doors" is ambiguous — 2 door panels (one pair) or 2
  complete pairs? Ask, don't guess.
- Finish without asking only when the request already states the job and its
  quantity unambiguously.

Rules for finishing (action "done"):
- category: the best-fitting category from: ${CATEGORIES.join(", ")}. Use ""
  if none fits.
- details: a short comma-separated summary of the cost-relevant facts the
  user confirmed. Phrase quantities canonically so the pricing engine can
  parse them: areas as "N sq ft", lengths as "N linear ft", counts as
  "N windows" / "N doors" / "N outlets", and french doors as "N pair(s) of
  french doors". Only include facts the user explicitly stated or confirmed —
  never resolve an ambiguity by guessing; if a quantity was never pinned
  down, leave it out of details.

The pricing engine covers these jobs — ask toward them, and note each one's
pricing unit (that's the quantity worth clarifying):
${TAXONOMY_LINES}`;
}

const SCHEMA = {
  type: "object",
  properties: {
    action: { type: "string", enum: ["ask", "done"] },
    question: { type: "string" },
    quick_replies: { type: "array", items: { type: "string" } },
    category: { type: "string", enum: [...CATEGORIES, ""] },
    details: { type: "string" },
  },
  required: ["action", "question", "quick_replies", "category", "details"],
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
  if (!Array.isArray(rawMessages) || rawMessages.length === 0 || rawMessages.length > 20) {
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
  const remaining = Math.max(0, MAX_QUESTIONS - asked);

  let parsed: {
    action?: string;
    question?: string;
    quick_replies?: string[];
    category?: string;
    details?: string;
  };
  try {
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: 20_000, maxRetries: 1 });
    const response = await client.messages.create({
      model: "claude-opus-4-8",
      max_tokens: 500,
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

  // Out of questions -> the model was told to finish; coerce if it didn't.
  if (parsed.action !== "done" && remaining === 0) {
    parsed = { action: "done", category: "", details: "" };
  }

  if (parsed.action === "ask" && parsed.question) {
    return json({
      action: "ask",
      question: parsed.question,
      quick_replies: (parsed.quick_replies ?? []).slice(0, 4),
    });
  }
  return json({
    action: "done",
    category: parsed.category ?? "",
    details: parsed.details ?? "",
  });
});
