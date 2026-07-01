// Supabase Edge Function: `search`
//
// Proxies Google Places Text Search so the API key stays server-side, and caches
// each first-page response in Postgres so one search per area/category/day serves
// everyone (Phase 2) instead of billing Google on every visit.
//
// The app POSTs { textQuery, latitude, longitude, pageSize, pageToken } and gets
// back Google's raw response, which the iOS client decodes as-is. An `x-cache`
// response header (hit/miss/bypass) makes it easy to verify caching.
//
// Deploy:   supabase functions deploy search
// Secret:   supabase secrets set GOOGLE_PLACES_KEY=<server-only key>
// Table:    supabase/migrations/*_search_cache.sql (run via `supabase db push`
//           or the dashboard SQL editor)
//
// NOTE: still unauthenticated (verify_jwt = false), bounded by the Google per-day
// quota cap. Real auth is a Phase 4 hardening step. See docs/cheap-api-plan.md.

import { createClient } from "jsr:@supabase/supabase-js@2";

const GOOGLE_KEY = Deno.env.get("GOOGLE_PLACES_KEY") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Service-role client bypasses RLS to read/write the cache. Nil if env missing —
// caching is then skipped and the function still proxies Google (best-effort).
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const SEARCH_URL = "https://places.googleapis.com/v1/places:searchText";
const FIELD_MASK = [
  "places.id", "places.displayName", "places.rating", "places.userRatingCount",
  "places.formattedAddress", "places.nationalPhoneNumber", "places.photos",
  "places.businessStatus", "places.reviews", "places.location", "nextPageToken",
].join(",");
const RADIUS_M = 40000;
const TTL_MS = 24 * 60 * 60 * 1000;   // reuse a cached search for a day

function json(payload: unknown, status = 200, cache = "bypass"): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", "x-cache": cache },
  });
}

// ~5km location buckets so nearby users share a cached search.
function bucket(v: number): string {
  return (Math.round(v / 0.05) * 0.05).toFixed(2);
}

function cacheKey(textQuery: string, lat: number, lng: number, pageSize: number): string {
  const day = new Date().toISOString().slice(0, 10);   // yyyy-mm-dd
  return `${textQuery}|${bucket(lat)}|${bucket(lng)}|${pageSize}|${day}`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!GOOGLE_KEY) return json({ error: "server key not configured" }, 500);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const textQuery = payload.textQuery;
  const latitude = payload.latitude;
  const longitude = payload.longitude;
  const pageToken = payload.pageToken;
  const pageSize = typeof payload.pageSize === "number" ? payload.pageSize : 20;

  if (typeof textQuery !== "string" || textQuery.length === 0 ||
      typeof latitude !== "number" || typeof longitude !== "number") {
    return json({ error: "missing textQuery / latitude / longitude" }, 400);
  }

  // Only first pages are cacheable (continuation tokens are one-shot).
  const key = (typeof pageToken === "string" && pageToken.length > 0)
    ? null
    : cacheKey(textQuery, latitude, longitude, pageSize);

  // 1. Cache read (best-effort — a failure just falls through to Google).
  if (key && db) {
    try {
      const { data } = await db.from("search_cache")
        .select("response, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        return json(data.response, 200, "hit");
      }
    } catch (_) { /* ignore, fall through to Google */ }
  }

  // 2. Google Text Search.
  const body: Record<string, unknown> = {
    textQuery,
    maxResultCount: pageSize,
    locationBias: { circle: { center: { latitude, longitude }, radius: RADIUS_M } },
  };
  if (typeof pageToken === "string" && pageToken.length > 0) body.pageToken = pageToken;

  const resp = await fetch(SEARCH_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": GOOGLE_KEY,
      "X-Goog-FieldMask": FIELD_MASK,
    },
    body: JSON.stringify(body),
  });
  const text = await resp.text();
  if (resp.status !== 200) {
    return new Response(text, {
      status: resp.status,
      headers: { "Content-Type": "application/json", "x-cache": "bypass" },
    });
  }

  // 3. Cache write (best-effort, first page only).
  if (key && db) {
    try {
      await db.from("search_cache").upsert({
        cache_key: key,
        response: JSON.parse(text),
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore */ }
  }

  return new Response(text, {
    status: 200,
    headers: { "Content-Type": "application/json", "x-cache": key ? "miss" : "bypass" },
  });
});
