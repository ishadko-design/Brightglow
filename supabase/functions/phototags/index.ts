// Supabase Edge Function: `phototags`
//
// Rich, query-independent semantic tags for a business's work photos, produced
// once by a vision model and cached/shared through the existing `verdicts`
// store. This is what makes photo relevance ranking work for specifics the
// on-device Apple Vision classifier can't name: it has NO token for "bumper",
// "windshield", a car make, etc. (its taxonomy is generic scene labels), so a
// search like "bumper for Mazda" never matches an on-device label and the photos
// stay in Google's raw order. A vision model tags each photo with the part,
// material, subject, and (when a badge is legible) the brand, and the client
// unions those tags into each photo's labels — which the existing
// `PhotoFilter.order` already ranks against the query.
//
// Cost is bounded and amortized: the client only calls this on the FIRST screen
// of a place (verdict-cache miss), so a place's pool is tagged at most once
// across all users. Images arrive as base64 bytes the client ALREADY downloaded
// for screening — so tagging adds no Google Places Photo billing.
//
// POST { vertical: "home" | "auto", photos: [{ url, image }] }   // image = base64 JPEG
//   -> { tags: { <url>: [string, ...] } }
//
// Deploy:  supabase functions deploy phototags
// Secrets: ANTHROPIC_API_KEY (shared with `clarify`/`pricing`; unset -> 503,
//          client keeps the on-device ordering).

import Anthropic from "npm:@anthropic-ai/sdk";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

// Bound the vision cost per call. A place returns at most ~10 Places photos and
// the client keeps a few work shots; tag every kept shot in one message.
const MAX_PHOTOS = 12;
// Guard the request body: a screening-rendition JPEG is tens of KB; reject
// anything wildly larger so a malformed client can't push huge payloads.
const MAX_IMAGE_BYTES = 700 * 1024;

function systemPrompt(vertical: string): string {
  const auto = vertical === "auto";
  const domain = auto
    ? `You are tagging photos from an AUTO / MOTORCYCLE shop so a driver's request \
can be matched to shops that show a similar job. For each photo, output short \
lowercase keywords a user might search:
- the vehicle: car, sedan, suv, truck, van, motorcycle, scooter
- the SPECIFIC part or area shown: bumper, front bumper, rear bumper, fender, \
door, hood, trunk, quarter panel, wheel, rim, tire, windshield, window, \
headlight, taillight, mirror, grille, engine, brake, exhaust, seat, dashboard
- the condition or work: dent, scratch, scrape, collision damage, rust, \
respray, repaint, primer, paint correction, detailing, ceramic coating, \
window tint, polish, wrap
- the paint color of the vehicle (e.g. red, silver, black)
- the make/brand (e.g. mazda, toyota, honda, bmw, ford) ONLY when a badge, \
logo, or lettering is clearly legible in the photo. NEVER guess a brand from \
the body shape.`
    : `You are tagging a home-services contractor's work photos so a homeowner's \
request can be matched to contractors who show a similar job. For each photo, \
output short lowercase keywords a user might search:
- the room or area: kitchen, bathroom, bedroom, living room, roof, exterior, \
yard, garage, driveway, deck, basement
- the element or fixture shown: cabinet, countertop, vanity, faucet, sink, \
toilet, shower, tub, tile, backsplash, flooring, window, door, fence, gutter, \
shingles, siding, drywall, outlet, water heater, furnace, panel
- the material: quartz, granite, marble, hardwood, laminate, vinyl, tile, \
porcelain, concrete, brick, stucco, asphalt shingle, metal
- the type of work: installation, remodel, replacement, repair, refinishing
- do NOT tag people or vehicles.`;

  return `${domain}

- If the photo is the SHOP ITSELF rather than a specific job — the business's \
storefront, building exterior, garage bay / shop interior, signage, or logo \
board (even if parked cars or a work area are visible) — tag it \`storefront\` \
(plus any other clearly-visible tags). This is NOT a job the user searched for, \
so it must never lead the results.

Rules:
- Tag ONLY what is clearly and confidently visible. Omit anything you're unsure \
of rather than guessing.
- 3 to 8 keywords per photo. Lowercase. Prefer the words a real person would \
type in a search.
- Return one entry per photo, in the SAME order the photos were given.`;
}

const SCHEMA = {
  type: "object",
  properties: {
    photos: {
      type: "array",
      items: { type: "array", items: { type: "string" } },
    },
  },
  required: ["photos"],
  additionalProperties: false,
} as const;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Rough base64 byte size (4 base64 chars ≈ 3 bytes), ignoring padding.
function b64Bytes(s: string): number {
  return Math.floor((s.length * 3) / 4);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!ANTHROPIC_API_KEY) return json({ error: "phototags unavailable" }, 503);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const vertical = payload.vertical === "auto" ? "auto" : "home";
  const rawPhotos = Array.isArray(payload.photos) ? payload.photos : [];
  const photos: { url: string; image: string }[] = [];
  for (const p of rawPhotos) {
    const url = (p as { url?: unknown })?.url;
    const image = (p as { image?: unknown })?.image;
    if (typeof url !== "string" || typeof image !== "string" || !image) continue;
    if (b64Bytes(image) > MAX_IMAGE_BYTES) continue;   // skip oversized, keep the rest
    photos.push({ url, image });
    if (photos.length >= MAX_PHOTOS) break;
  }
  if (photos.length === 0) return json({ tags: {} });

  // One vision message: an image block per photo, numbered so the model returns
  // tags in the same order.
  // deno-lint-ignore no-explicit-any
  const content: any[] = [];
  photos.forEach((p, i) => {
    content.push({ type: "text", text: `Photo ${i + 1}:` });
    content.push({
      type: "image",
      source: { type: "base64", media_type: "image/jpeg", data: p.image },
    });
  });
  content.push({
    type: "text",
    text: `Tag all ${photos.length} photos above. Return {"photos": [...]} with `
      + `exactly ${photos.length} keyword arrays, one per photo, in order.`,
  });

  let parsed: { photos?: string[][] };
  try {
    const client = new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: 25_000, maxRetries: 1 });
    const response = await client.messages.create({
      model: "claude-sonnet-5",
      max_tokens: 700,
      system: systemPrompt(vertical),
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content }],
    });
    const text = response.content.find((b) => b.type === "text")?.text ?? "";
    parsed = JSON.parse(text);
  } catch (err) {
    console.error("phototags: model call failed", err);
    return json({ error: "phototags failed" }, 502);
  }

  // Map the ordered tag arrays back onto the photo URLs. A short/missing array
  // just yields no tags for that photo (the client keeps its on-device labels).
  const tagArrays = Array.isArray(parsed.photos) ? parsed.photos : [];
  const out: Record<string, string[]> = {};
  photos.forEach((p, i) => {
    const tags = Array.isArray(tagArrays[i]) ? tagArrays[i] : [];
    const clean = tags
      .filter((t): t is string => typeof t === "string")
      .map((t) => t.trim().toLowerCase())
      .filter((t) => t.length > 0 && t.length <= 40)
      .slice(0, 8);
    if (clean.length > 0) out[p.url] = [...new Set(clean)];
  });

  return json({ tags: out });
});
