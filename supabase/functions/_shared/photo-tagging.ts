// Shared photo-tagging logic for the `phototags` (client-driven) and `photo`
// (proxy piggyback) Edge Functions.
//
// Tags are keyed by the STABLE photo resource name
// ("places/<place_id>/photos/<photo_id>") — not by rendition URL — so the 512px
// screening rendition and the 1600px gallery rendition share one tag row, and
// one VLM call per photo serves every user, every vertical, indefinitely
// (persisted in `public.photo_tags`, read by `phototags` and `verdicts`).

import Anthropic from "npm:@anthropic-ai/sdk";

export type TagVertical = "home" | "auto" | "both";

export const TAG_MODEL = "claude-sonnet-5";

// Prompt/tag-schema version, stored in photo_tags.model alongside TAG_MODEL.
// Bump when the prompt changes (new tag kinds, new synonyms): the phototags
// cache-skip only honors rows at the current version, so a bump re-tags every
// photo exactly once fleet-wide instead of serving stale-schema tags forever.
// The verdicts union path stays version-agnostic — old tags are better than
// none while the re-tag wave propagates.
export const TAG_VERSION = `${TAG_MODEL}/p2`;

// Bound the vision cost per call. A place returns at most ~10 Places photos;
// tag every photo in one message.
const MAX_PHOTOS = 12;
// Guard the request body: a screening-rendition JPEG is tens of KB; reject
// anything wildly larger so a malformed caller can't push huge payloads.
const MAX_IMAGE_BYTES = 700 * 1024;

function systemPrompt(vertical: TagVertical): string {
  const homePart = `HOME services: the room or area (kitchen, bathroom, bedroom, \
living room, roof, exterior, yard, garage, driveway, deck, basement), the \
element or fixture shown (cabinet, countertop, vanity, faucet, sink, toilet, \
shower, tub, tile, backsplash, flooring, window, door, fence, gutter, shingles, \
siding, drywall, outlet, water heater, furnace, panel), the material (quartz, \
granite, marble, hardwood, laminate, vinyl, tile, porcelain, concrete, brick, \
stucco, asphalt shingle, metal), the type of work (installation, remodel, \
replacement, repair, refinishing)`;
  const autoPart = `AUTO / MOTORCYCLE shops: the vehicle (car, sedan, suv, \
truck, van, motorcycle, scooter), the SPECIFIC part or area shown (bumper, \
front bumper, rear bumper, fender, door, hood, trunk, quarter panel, wheel, \
rim, tire, windshield, window, headlight, taillight, mirror, grille, engine, \
brake, exhaust, seat, dashboard), the condition or work (dent, scratch, scrape, \
collision damage, rust, respray, repaint, primer, paint correction, detailing, \
ceramic coating, window tint, polish, wrap), the paint color of the vehicle \
(e.g. red, silver, black), the make/brand (e.g. mazda, toyota, honda, bmw, \
ford) ONLY when a badge, logo, or lettering is clearly legible in the photo. \
NEVER guess a brand from the body shape`;

  const domain =
    vertical === "auto"
      ? `You are tagging photos from an AUTO / MOTORCYCLE shop so a driver's \
request can be matched to shops that show a similar job. For each photo, output \
short lowercase keywords a user might search:\n- ${autoPart}`
      : vertical === "home"
        ? `You are tagging a home-services contractor's work photos so a \
homeowner's request can be matched to contractors who show a similar job. For \
each photo, output short lowercase keywords a user might search:\n- ${homePart}`
        : `You are tagging a contractor's work photos so a customer's request \
can be matched to businesses that show a similar job. This covers BOTH home \
services and auto/motorcycle shops. For each photo, output short lowercase \
keywords a user might search:\n- ${homePart}\n- ${autoPart}\n- do NOT tag \
people or vehicles as subjects of home work (a van in the driveway is not the \
job).`;

  return `${domain}

- If the photo is the SHOP ITSELF rather than a specific job — the business's \
storefront, building exterior, garage bay / shop interior, signage, or logo \
board (even if parked cars or a work area are visible) — tag it \`storefront\` \
(plus any other clearly-visible tags). This is NOT a job the user searched for, \
so it must never lead the results.

- THE JOB TAG: if the photo clearly shows ONE specific trade job — the work \
being done or its finished result (a furnace install, an air-conditioner \
condenser, a water heater, a roof replacement, a bumper respray) — add ONE tag \
\`job:<canonical-noun>\` using the same canonical noun as your plain tag \
(\`job:furnace\`, \`job:air conditioner\`, \`job:water heater\`). This is how \
the app tells "a photo OF the searched job" from "a photo of other work". Omit \
it when no single job is identifiable (generic tools, materials, vans, \
storefronts — a storefront gets the \`storefront\` tag, never a \`job:\` tag).

- SYNONYMS: emit BOTH the specific term and the common words a customer would \
type in a search. A gas furnace is "furnace", "gas furnace", AND "heater". A \
heat pump is "heat pump" and "hvac". A water heater is "water heater" and "hot \
water heater". An HVAC condenser is "condenser", "ac", and "air conditioner". \
Prefer the words a real person would type over trade jargon.

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

// Rough base64 byte size (4 base64 chars ≈ 3 bytes), ignoring padding.
function b64Bytes(s: string): number {
  return Math.floor((s.length * 3) / 4);
}

/// Stable identity of a Google Places photo inside any media URL, or null for
/// non-Places URLs (business-website images, uploads).
export function photoNameFromUrl(url: string): string | null {
  const m = url.match(/places\/[A-Za-z0-9_-]+\/photos\/[A-Za-z0-9_-]+/);
  return m ? m[0] : null;
}

/// The place id embedded in a photo resource name, or null.
export function placeIdFromPhotoName(name: string): string | null {
  const m = name.match(/^places\/([A-Za-z0-9_-]+)\/photos\//);
  return m ? m[1] : null;
}

/// Tag one batch of images with the vision model. `key` is the caller's stable
/// identity for the photo (photo resource name, or the full URL for
/// non-Places photos). Returns tags keyed by that same key; photos the model
/// had nothing for are simply absent.
export async function tagImageBatch(
  apiKey: string,
  images: { key: string; base64: string }[],
  vertical: TagVertical,
): Promise<Record<string, string[]>> {
  const usable = images
    .filter((i) => i.key && i.base64 && b64Bytes(i.base64) <= MAX_IMAGE_BYTES)
    .slice(0, MAX_PHOTOS);
  if (usable.length === 0 || !apiKey) return {};

  // One vision message: an image block per photo, numbered so the model returns
  // tags in the same order.
  // deno-lint-ignore no-explicit-any
  const content: any[] = [];
  usable.forEach((p, i) => {
    content.push({ type: "text", text: `Photo ${i + 1}:` });
    content.push({
      type: "image",
      source: { type: "base64", media_type: "image/jpeg", data: p.base64 },
    });
  });
  content.push({
    type: "text",
    text: `Tag all ${usable.length} photos above. Return {"photos": [...]} with `
      + `exactly ${usable.length} keyword arrays, one per photo, in order.`,
  });

  let parsed: { photos?: string[][] };
  try {
    const client = new Anthropic({ apiKey, timeout: 25_000, maxRetries: 1 });
    const response = await client.messages.create({
      model: TAG_MODEL,
      max_tokens: 700,
      system: systemPrompt(vertical),
      output_config: { format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content }],
    });
    const text = response.content.find((b) => b.type === "text")?.text ?? "";
    parsed = JSON.parse(text);
  } catch (err) {
    console.error("photo-tagging: model call failed", err);
    return {};
  }

  // Map the ordered tag arrays back onto the caller's keys. A short/missing
  // array just yields no tags for that photo.
  const tagArrays = Array.isArray(parsed.photos) ? parsed.photos : [];
  const out: Record<string, string[]> = {};
  usable.forEach((p, i) => {
    const tags = Array.isArray(tagArrays[i]) ? tagArrays[i] : [];
    const clean = tags
      .filter((t): t is string => typeof t === "string")
      .map((t) => t.trim().toLowerCase())
      .filter((t) => t.length > 0 && t.length <= 40)
      .slice(0, 8);
    if (clean.length > 0) out[p.key] = [...new Set(clean)];
  });
  return out;
}

/// Look up stored tags for a batch of keys. Returns the subset that already
/// has tags (key -> tags). When `version` is given, only rows tagged at that
/// prompt version count — the phototags cache-skip passes TAG_VERSION so a
/// prompt bump re-tags stale-schema rows; callers that just want "any tags"
/// (the verdicts union) omit it.
// deno-lint-ignore no-explicit-any
export async function lookupStoredTags(
  db: any,
  keys: string[],
  version?: string,
): Promise<Record<string, string[]>> {
  const uniq = [...new Set(keys.filter(Boolean))];
  if (!db || uniq.length === 0) return {};
  // Chunk the IN list so a big pool can't blow up the query.
  const out: Record<string, string[]> = {};
  for (let i = 0; i < uniq.length; i += 200) {
    const chunk = uniq.slice(i, i + 200);
    const { data, error } = await db.from("photo_tags").select("photo_name, tags, model").in("photo_name", chunk);
    if (error) {
      console.error("photo-tagging: tag lookup failed", error);
      continue;
    }
    for (const row of data ?? []) {
      if (row.photo_name && Array.isArray(row.tags) && row.tags.length > 0
          && (!version || row.model === version)) {
        out[row.photo_name as string] = (row.tags as string[]).map(String);
      }
    }
  }
  return out;
}

/// Persist fresh tags. Last write wins on conflict: a re-tag at a new prompt
/// version overwrites the stale-schema row (same-version concurrent writes are
/// harmless — near-identical content). Stored with TAG_VERSION so the
/// cache-skip can tell stale rows from current ones.
// deno-lint-ignore no-explicit-any
export async function storePhotoTags(
  db: any,
  rows: { photo_name: string; tags: string[] }[],
): Promise<void> {
  const payload = rows
    .filter((r) => r.photo_name && r.tags.length > 0)
    .map((r) => ({
      photo_name: r.photo_name,
      place_id: placeIdFromPhotoName(r.photo_name),
      tags: [...new Set(r.tags.map((t) => t.trim().toLowerCase()).filter(Boolean))],
      model: TAG_VERSION,
      tagged_at: new Date().toISOString(),
    }));
  if (!db || payload.length === 0) return;
  const { error } = await db.from("photo_tags").upsert(payload, {
    onConflict: "photo_name",
  });
  if (error) console.error("photo-tagging: tag store failed", error);
}
