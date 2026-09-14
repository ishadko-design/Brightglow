// Supabase Edge Function: `classify`
//
// The capture-time photo recognition brain. The client sends the captured photo
// (base64 JPEG, already downscaled) plus the assembled routing prompt, and this
// runs a strong vision model (Claude Sonnet 5) to return the one-line
// `CATEGORY | DETAILS | DESCRIPTION` verdict the client parses.
//
// Why server-side: the recognition used to call an open Qwen model on the HF
// router directly from the app. Qwen mislabelled the subject (an overhang for a
// garage door), invented detail (glass in a solid door), and misread badges — a
// model-capability ceiling no prompt could lift. A model bake-off on real capture
// photos (garage door, solid door, ductwork, cabinets, cracked slider, vehicles)
// put Sonnet far ahead of Qwen and Haiku and level with Opus at ~⅓ the cost/
// latency, so recognition moved here: Sonnet's reads, the API key off-device, and
// one prompt to evolve without an app release.
//
// The client keeps the on-device Apple Vision fallback, the region-crop redo, the
// dominance gate, and all parsing — this only swaps the cloud brain.
//
// POST { categories: {home, auto}, image, media_type?, hint?, region? }
//   image  = base64 (default JPEG)
//   region = true when the client sends a photo with a drawn loop → the server
//            appends the REGION_OVERRIDE_HINT instead of the dominance `hint`.
//   -> { content: "<CATEGORY | DETAILS | DESCRIPTION | CONFIDENCE>" }
//
// The recognition PROMPT lives server-side (./prompt.ts) so it can evolve with a
// redeploy, no app release (moved out of the iOS client 2026-09-06). The client
// sends the live category lists so those never drift from the app. Legacy apps
// already in the wild send a fully-assembled `prompt` (and the override as
// `hint`); that path is still honored below so they keep working.
//
// Deploy:  supabase functions deploy classify
// Secrets: ANTHROPIC_API_KEY (shared with clarify/pricing/phototags; unset -> 503,
//          client falls back to on-device Apple Vision).

import Anthropic from "npm:@anthropic-ai/sdk";
import { buildPrompt, REGION_OVERRIDE_HINT } from "./prompt.ts";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

// A downscaled capture JPEG (~1280px long edge) is a few hundred KB; reject
// anything wildly larger so a malformed client can't push a huge payload.
const MAX_IMAGE_BYTES = 3 * 1024 * 1024;

// Rough base64 byte size (4 base64 chars ≈ 3 bytes), ignoring padding.
function b64Bytes(s: string): number {
  return Math.floor((s.length * 3) / 4);
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
  if (!ANTHROPIC_API_KEY) return json({ error: "classify unavailable" }, 503);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const image = typeof payload.image === "string" ? payload.image : "";
  const mediaType = typeof payload.media_type === "string" ? payload.media_type : "image/jpeg";

  // PROMPT: build it server-side from the client's live category lists (current
  // apps), or honor a fully-assembled `prompt` from legacy apps in the wild.
  const legacyPrompt = typeof payload.prompt === "string" ? payload.prompt : "";
  const categories = (payload.categories ?? {}) as { home?: unknown; auto?: unknown };
  const home = typeof categories.home === "string" ? categories.home : "";
  const auto = typeof categories.auto === "string" ? categories.auto : "";
  const prompt = legacyPrompt || (home && auto ? buildPrompt(home, auto) : "");

  // HINT: a drawn-loop capture sets `region: true` → append the server's override
  // text. Otherwise ride the per-photo dominance hint the client computed. (Legacy
  // apps send the override text directly as `hint`, so that still works too.)
  const hint = payload.region === true
    ? REGION_OVERRIDE_HINT
    : (typeof payload.hint === "string" ? payload.hint : "");

  if (!prompt || !image) return json({ error: "missing categories or image" }, 400);
  if (b64Bytes(image) > MAX_IMAGE_BYTES) return json({ error: "image too large" }, 413);

  // The routing prompt is stable across every capture, so cache it — only the
  // image (and the small per-photo hint) change. The image follows the prompt,
  // matching the layout the model was evaluated on.
  // deno-lint-ignore no-explicit-any
  const content: any[] = [
    { type: "text", text: prompt, cache_control: { type: "ephemeral" } },
    {
      type: "image",
      source: {
        type: "base64",
        media_type: mediaType as "image/jpeg" | "image/png" | "image/webp",
        data: image,
      },
    },
  ];
  if (hint) content.push({ type: "text", text: hint });

  let text = "";
  try {
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: 20_000, maxRetries: 1 });
    const response = await client.messages.create({
      model: "claude-sonnet-5",
      max_tokens: 512,
      messages: [{ role: "user", content }],
    });
    text = response.content
      .filter((b) => b.type === "text")
      .map((b) => (b as { text: string }).text)
      .join(" ")
      .trim();
  } catch (err) {
    console.error("classify: model call failed", err);
    return json({ error: "classify failed" }, 502);
  }

  return json({ content: text });
});
