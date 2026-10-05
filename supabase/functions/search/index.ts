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
import { collapseFranchises } from "./franchise.ts";
import { betterQueryFor, deriveJob, type DerivedJob, gatePlaces, type GateJob, rememberBetterQuery } from "./gate.ts";

const GOOGLE_KEY = Deno.env.get("GOOGLE_PLACES_KEY") ?? "";
// Shared-token gate (Phase 4). Enforced only when APP_TOKEN is set as a secret,
// so the function stays open until you opt in — no lockout during rollout.
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Service-role client bypasses RLS to read/write the cache. Nil if env missing —
// caching is then skipped and the function still proxies Google (best-effort).
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const SEARCH_URL = "https://places.googleapis.com/v1/places:searchText";
const FIELD_MASK = [
  "places.id", "places.displayName", "places.rating", "places.userRatingCount",
  "places.formattedAddress", "places.nationalPhoneNumber", "places.websiteUri", "places.photos",
  "places.businessStatus", "places.reviews", "places.location", "places.types", "nextPageToken",
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

// LeadBridge (the Node relay) owns email resolution — its resolver lives there.
// The search fn only reads the cache and kicks off resolution for misses.
const LEADBRIDGE_URL = (Deno.env.get("LEADBRIDGE_URL") ?? "").replace(/\/+$/, "");
const LEADBRIDGE_ADMIN_TOKEN = Deno.env.get("LEADBRIDGE_ADMIN_TOKEN") ?? "";

// Attaches `contactEmail` to each place from the business_places cache — the
// signal the app uses to show "Request quote" (email thread) vs "Call". Places
// we haven't checked yet are sent to LeadBridge to resolve in the background,
// so the search latency is unaffected and the next search for them is warm.
// Best-effort throughout: any failure just leaves contactEmail null (Call only).
async function enrichContacts(responseObj: unknown, lat?: number, lng?: number): Promise<unknown> {
  const obj = responseObj as { places?: Array<Record<string, unknown>> };
  // One location per franchise brand (nearest) — siblings share a website and
  // corporate photos and read as duplicates. Done here, the single choke point
  // every response passes through; never mutates the cached raw response.
  if (Array.isArray(obj?.places) && typeof lat === "number" && typeof lng === "number") {
    const collapsed = collapseFranchises(obj.places, lat, lng);
    if (collapsed.length !== obj.places.length) {
      responseObj = { ...(responseObj as object), places: collapsed };
      return enrichContacts(responseObj, undefined, undefined);
    }
  }
  const places = Array.isArray(obj?.places) ? obj.places : [];
  if (!places.length || !db) return responseObj;
  const ids = places.map((p) => p.id).filter(Boolean) as string[];
  if (!ids.length) return responseObj;

  const emailById = new Map<string, string | null>();
  const checked = new Set<string>();
  const hidden = new Set<string>();
  try {
    const { data } = await db
      .from("business_places")
      .select("place_id, contact_email, contact_checked_at, hidden_at")
      .in("place_id", ids);
    for (const row of data ?? []) {
      emailById.set(row.place_id, row.contact_email ?? null);
      if (row.contact_checked_at) checked.add(row.place_id);
      if (row.hidden_at) hidden.add(row.place_id);
    }
  } catch (_) { /* best-effort */ }

  // Responsiveness signal: a business that has CLAIMED its page and is accepting
  // work is the one most likely to reply — and the one that hits the paywall, so
  // the app boosts it in the ranking (an OTA-tunable `responsiveness` weight).
  // Server-owned so the signal reaches every build without a release; the client
  // also mines reviews for responsiveness, so the two combine into one weight.
  // Best-effort: any failure just leaves `responsive` false (no boost).
  const responsiveIds = new Set<string>();
  try {
    const { data } = await db
      .from("business_profiles")
      .select("place_id, accepting_work")
      .in("place_id", ids);
    for (const row of data ?? []) {
      // A claimed profile counts as responsive unless it explicitly turned work
      // off (accepting_work defaults true, so a null/absent flag still counts).
      if (row.accepting_work !== false) responsiveIds.add(row.place_id);
    }
  } catch (_) { /* best-effort */ }

  // Drop paywalled-and-lapsed businesses entirely — they're hidden from search
  // until they subscribe (see the LeadBridge paywall sweep). Demand re-routes to
  // businesses that are actually reachable/paying.
  const visible = places.filter((p) => !hidden.has(p.id as string));
  (obj as { places?: unknown }).places = visible;

  for (const p of visible) {
    p.contactEmail = emailById.get(p.id as string) ?? null;
    p.responsive = responsiveIds.has(p.id as string);
  }

  const toResolve = visible
    .filter((p) => p.id && p.websiteUri && !checked.has(p.id as string))
    .slice(0, 25)
    .map((p) => ({
      place_id: p.id,
      website: p.websiteUri,
      business_name: (p.displayName as { text?: string } | undefined)?.text ?? null,
    }));
  if (toResolve.length && LEADBRIDGE_URL && LEADBRIDGE_ADMIN_TOKEN) {
    const task = fetch(`${LEADBRIDGE_URL}/internal/resolve-contacts`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-admin-token": LEADBRIDGE_ADMIN_TOKEN },
      body: JSON.stringify({ places: toResolve }),
    }).catch(() => {});
    // Run after the response is flushed so it adds no latency to the search.
    (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } })
      .EdgeRuntime?.waitUntil?.(task);
  }
  return responseObj;
}

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

/** deriveJob, persisted in search_cache (key "derive:<text>", no TTL — a
 *  trade decision doesn't go stale) so every isolate and every page agrees. */
async function derivedCached(text: string): Promise<DerivedJob | null> {
  const key = `derive:${text.toLowerCase().replace(/\s+/g, " ").trim()}`.slice(0, 300);
  if (db) {
    try {
      const { data } = await db.from("search_cache").select("response").eq("cache_key", key).maybeSingle();
      const r = data?.response as DerivedJob | undefined;
      if (r?.query && Array.isArray(r.trades)) return r;
    } catch (_) { /* fall through */ }
  }
  const d = await deriveJob(text, ANTHROPIC_API_KEY);
  if (d && db) {
    try {
      await db.from("search_cache").upsert({ cache_key: key, response: d, created_at: new Date().toISOString() });
    } catch (_) { /* ignore */ }
  }
  if (d) console.log("search: derived", JSON.stringify({ text, ...d }));
  return d;
}

/** Drop places that are the wrong KIND of business for the clarified job
 *  (see gate.ts). Runs per request on a structuredClone so the cached raw
 *  Google response is never mutated. No job / no key / gate failure -> the
 *  response passes through untouched (fail open: today's behavior). */
async function gateCacheKey(job: unknown, ids: string[]): Promise<string> {
  const data = new TextEncoder().encode(JSON.stringify(job) + "|" + ids.join(","));
  const h = await crypto.subtle.digest("SHA-256", data);
  return "gate2:" + [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 40);
}

async function gate(responseObj: unknown, job: unknown): Promise<unknown> {
  if (!job || typeof job !== "object" || !ANTHROPIC_API_KEY) return responseObj;
  const obj = structuredClone(responseObj) as { places?: Array<Record<string, unknown>> };
  if (!Array.isArray(obj?.places) || obj.places.length === 0) return responseObj;
  // The gate is an LLM call (seconds) and its memo is per-isolate, so a cold
  // isolate re-ran it for a job + result list someone had already gated. Persist
  // the verdict by job + place ids (2026-10-05, "7 to 10 seconds" to results).
  const ids = obj.places.map((p) => String(p.id ?? "")).sort();
  const gkey = await gateCacheKey(job, ids);
  let keep: Set<string> | null = null;
  if (db) {
    try {
      const { data } = await db.from("search_cache").select("response, created_at").eq("cache_key", gkey).maybeSingle();
      const r = data?.response as { keep?: string[]; better?: string } | undefined;
      const fresh = data ? Date.now() - new Date(data.created_at as string).getTime() < 30 * 24 * 3600_000 : false;
      if (fresh && Array.isArray(r?.keep)) {
        keep = new Set(r!.keep);
        if (r!.better) rememberBetterQuery(job as GateJob, r!.better);
      }
    } catch (_) { /* fall through to the model */ }
  }
  if (!keep) {
    keep = await gatePlaces(job as GateJob, obj.places, ANTHROPIC_API_KEY);
    if (keep && db) {
      try {
        await db.from("search_cache").upsert({
          cache_key: gkey,
          response: { keep: [...keep], better: betterQueryFor(job as GateJob) },
          created_at: new Date().toISOString(),
        });
      } catch (_) { /* ignore */ }
    }
  }
  if (!keep) return responseObj;
  const before = obj.places.length;
  obj.places = obj.places.filter((p) => keep.has(p.id as string));
  console.log("search: gate", JSON.stringify({
    job: (job as GateJob).title ?? "",
    kept: obj.places.length,
    dropped: before - obj.places.length,
  }));
  return obj;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!GOOGLE_KEY) return json({ error: "server key not configured" }, 500);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  let textQuery = payload.textQuery;
  const latitude = payload.latitude;
  const longitude = payload.longitude;
  const pageToken = payload.pageToken;
  const pageSize = typeof payload.pageSize === "number" ? payload.pageSize : 20;

  if (typeof textQuery !== "string" || textQuery.length === 0 ||
      typeof latitude !== "number" || typeof longitude !== "number") {
    return json({ error: "missing textQuery / latitude / longitude" }, 400);
  }

  // Unclarified job (no chat → no trades): derive the trade + the Maps phrase
  // once, persist it, and search with THAT phrase instead of the raw sentence
  // (which finds product shops). Applied to every page, so a page token always
  // continues the same query. Fail open: no derivation → raw text, as before.
  const job = payload.job as GateJob | undefined;
  if (job && typeof job === "object" && !(job.spec?.trades?.length) && ANTHROPIC_API_KEY) {
    const derived = await derivedCached(String(job.title || job.summary || textQuery));
    if (derived) {
      job.spec = { ...(job.spec ?? {}), trades: derived.trades };
      textQuery = derived.query;
    }
  }

  // Only first pages are cacheable (continuation tokens are one-shot).
  const key = (typeof pageToken === "string" && pageToken.length > 0)
    ? null
    : cacheKey(textQuery as string, latitude, longitude, pageSize);

  // 1. Cache read (best-effort — a failure just falls through to Google).
  if (key && db) {
    try {
      const { data } = await db.from("search_cache")
        .select("response, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        const gated = await gate(data.response, payload.job);
        return json(await enrichContacts(
          await widenIfThin(gated, payload, latitude, longitude, pageSize, pageToken), latitude, longitude), 200, "hit");
      }
    } catch (_) { /* ignore, fall through to Google */ }
  }

  // 2. Google Text Search.
  const result = await googleSearch(textQuery as string, latitude, longitude, pageSize, pageToken, key);
  if (result instanceof Response) return result;
  const gated = await gate(result, payload.job);
  return json(await enrichContacts(await widenIfThin(gated, payload, latitude, longitude, pageSize, pageToken),
    latitude, longitude), 200, key ? "miss" : "bypass");
});

/** Google Text Search + first-page cache write. Returns the parsed response,
 *  or a Response to hand straight back (an upstream error / non-JSON). */
async function googleSearch(
  textQuery: string, latitude: number, longitude: number, pageSize: number,
  pageToken: unknown, key: string | null,
): Promise<unknown | Response> {
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

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (_) {
    // Non-JSON 200 (shouldn't happen from Google) — return raw, unenriched.
    return new Response(text, {
      status: 200,
      headers: { "Content-Type": "application/json", "x-cache": "bypass" },
    });
  }

  // 3. Cache write (best-effort, first page only). Cache the RAW Google response;
  // emails are enriched per-request so a cached search never serves stale contacts.
  if (key && db) {
    try {
      await db.from("search_cache").upsert({
        cache_key: key,
        response: parsed,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore */ }
  }

  return parsed;
}

/** A gated FIRST page that kept fewer than THIN_MIN places means the query
 *  itself was wrong (a raw "install 9kw outdoor sauna" finds sauna shops, all
 *  correctly dropped). Re-search once with the business-type query the gate
 *  suggested ("electrician sauna wiring"), gate that too, and append — so the
 *  user gets the right businesses instead of a near-empty list. */
const THIN_MIN = 5;
async function widenIfThin(
  gated: unknown, payload: Record<string, unknown>,
  latitude: number, longitude: number, pageSize: number, pageToken: unknown,
): Promise<unknown> {
  const job = payload.job as GateJob | undefined;
  const obj = gated as { places?: Array<Record<string, unknown>>; nextPageToken?: string };
  if (!job || pageToken || !Array.isArray(obj?.places) || obj.places.length >= THIN_MIN) return gated;
  const better = betterQueryFor(job);
  if (!better || better.toLowerCase() === String(payload.textQuery).toLowerCase()) return gated;
  const altKey = cacheKey(better, latitude, longitude, pageSize);
  let alt: unknown = null;
  if (db) {
    try {
      const { data } = await db.from("search_cache")
        .select("response, created_at").eq("cache_key", altKey).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) alt = data.response;
    } catch (_) { /* fall through */ }
  }
  if (!alt) {
    const r = await googleSearch(better, latitude, longitude, pageSize, undefined, altKey);
    if (r instanceof Response) return gated;
    alt = r;
  }
  const altGated = await gate(alt, job) as { places?: Array<Record<string, unknown>>; nextPageToken?: string };
  const have = new Set(obj.places.map((p) => p.id));
  const extra = (altGated.places ?? []).filter((p) => !have.has(p.id));
  console.log("search: widened", JSON.stringify({ from: payload.textQuery, to: better, added: extra.length }));
  // Continue paging the better query: the original one has nothing left to give.
  return { ...obj, places: [...obj.places, ...extra], nextPageToken: altGated.nextPageToken ?? obj.nextPageToken };
}
