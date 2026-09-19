// Supabase Edge Function: `embed`
//
// Text → meaning fingerprint (embedding) via Cloudflare Workers AI.
// Used once per search to embed the query text; photo fingerprints are
// computed at tag time in `phototags` with the SAME model. The client
// compares fingerprints with cosine similarity instead of word overlap.
//
// Model + dimensions are a frozen contract: photo fingerprints stored in
// `photo_tags.embedding` (vector(384)) MUST come from this same model.
// If the model ever changes, every stored fingerprint must be recomputed.
//
// POST { text: string } -> { embedding: [number x384], model: string }
//
// Deploy:  supabase functions deploy embed
// Secrets: CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_AI_TOKEN (Workers AI read).
//          Unset -> 503, caller falls back to word matching.

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const CF_ACCOUNT_ID = Deno.env.get("CLOUDFLARE_ACCOUNT_ID") ?? "";
const CF_AI_TOKEN = Deno.env.get("CLOUDFLARE_AI_TOKEN") ?? "";

// Frozen contract: bge-small-en-v1.5 emits 384-dim vectors. Changing this
// requires recomputing every fingerprint in photo_tags.embedding.
const MODEL = "@cf/baai/bge-small-en-v1.5";
const DIMS = 384;

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
  if (!CF_ACCOUNT_ID || !CF_AI_TOKEN) {
    return json({ error: "embed unavailable" }, 503);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }
  const text = typeof payload.text === "string" ? payload.text.trim() : "";
  if (!text) return json({ error: "text is required" }, 400);
  if (text.length > 2000) return json({ error: "text too long" }, 400);

  let data: unknown;
  try {
    const res = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/ai/run/${MODEL}`,
      {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${CF_AI_TOKEN}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ text }),
      },
    );
    if (!res.ok) {
      console.error("embed: workers AI status", res.status);
      return json({ error: "embed failed" }, 502);
    }
    const body = await res.json();
    data = body?.result?.data;
  } catch (err) {
    console.error("embed: workers AI call failed", err);
    return json({ error: "embed failed" }, 502);
  }

  // Single-text input yields a flat float array; be liberal in what we accept.
  const flat = Array.isArray(data) && Array.isArray(data[0]) ? data[0] : data;
  if (!Array.isArray(flat) || flat.length !== DIMS ||
      !flat.every((v) => typeof v === "number" && Number.isFinite(v))) {
    console.error("embed: unexpected vector shape");
    return json({ error: "embed failed" }, 502);
  }

  return json({ embedding: flat, model: MODEL });
});
