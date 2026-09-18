// Supabase Edge Function: `phototags`
//
// Rich, query-independent semantic tags for a business's work photos, produced
// once by a vision model and shared through the `photo_tags` store (and the
// `verdicts` kept labels). This is what makes photo relevance ranking work for
// specifics the on-device Apple Vision classifier can't name: it has NO token
// for "furnace", "bumper", "windshield", a car make, etc. (its taxonomy is
// generic scene labels), so a search like "replace gas furnace" never matches
// an on-device label and the photos stay in Google's raw order. A vision model
// tags each photo with the part, material, subject, and (when a badge is
// legible) the brand, and the client unions those tags into each photo's
// labels — which the existing `PhotoFilter.order` already ranks against the
// query.
//
// Cost is bounded and amortized: stored tags are checked FIRST, so a photo is
// vision-tagged at most once globally — across all users, both verticals, and
// verdict refreshes — instead of once per 30-day verdict cycle. Images arrive
// as base64 bytes the client ALREADY downloaded for screening — so tagging
// adds no Google Places Photo billing.
//
// POST { vertical: "home" | "auto", photos: [{ url, image }] }   // image = base64 JPEG
//   -> { tags: { <url>: [string, ...] } }
//
// Deploy:  supabase functions deploy phototags
// Secrets: ANTHROPIC_API_KEY (shared with `clarify`/`pricing`; unset -> 503,
//          client keeps the on-device ordering).
// Table:   supabase/migrations/*_photo_tags.sql

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  tagImageBatch,
  lookupStoredTags,
  storePhotoTags,
  photoNameFromUrl,
  type TagVertical,
} from "../_shared/photo-tagging.ts";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Service-role client bypasses RLS to read/write the shared tag store.
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

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
  if (!ANTHROPIC_API_KEY) return json({ error: "phototags unavailable" }, 503);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const vertical: TagVertical = payload.vertical === "auto" ? "auto" : "home";
  const rawPhotos = Array.isArray(payload.photos) ? payload.photos : [];
  const photos: { url: string; key: string; image: string }[] = [];
  for (const p of rawPhotos) {
    const url = (p as { url?: unknown })?.url;
    const image = (p as { image?: unknown })?.image;
    if (typeof url !== "string" || typeof image !== "string" || !image) continue;
    // Stable identity: the photo resource name for Places photos, else the
    // full URL (business-website images, uploads).
    photos.push({ url, key: photoNameFromUrl(url) ?? url, image });
    if (photos.length >= 12) break;
  }
  if (photos.length === 0) return json({ tags: {} });

  // Serve whatever the shared store already has — no VLM call for those.
  const stored = await lookupStoredTags(db, photos.map((p) => p.key));

  // Vision-tag only the photos nobody has tagged yet, then persist them so
  // the next caller (any user, either vertical, any verdict refresh) reuses
  // the row instead of re-calling the model.
  const missing = photos.filter((p) => !stored[p.key]);
  let fresh: Record<string, string[]> = {};
  if (missing.length > 0) {
    fresh = await tagImageBatch(
      ANTHROPIC_API_KEY,
      missing.map((p) => ({ key: p.key, base64: p.image })),
      vertical,
    );
    await storePhotoTags(
      db,
      Object.entries(fresh).map(([photo_name, tags]) => ({ photo_name, tags })),
    );
  }

  const out: Record<string, string[]> = {};
  for (const p of photos) {
    const tags = stored[p.key] ?? fresh[p.key];
    if (tags && tags.length > 0) out[p.url] = tags;
  }
  return json({ tags: out });
});
