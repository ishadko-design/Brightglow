// Supabase Edge Function: `pricing`
//
// Replaces the fake "$100-250" estimate with a data-backed "Local All-In
// Cost Range": SF DBI permit valuations (data.sfgov.org) blended with
// retail material pricing sourced live from SerpApi's Home Depot engine —
// the client only sends the job, not a materials list.
//
// The app POSTs { job_type, scope: {job_type, width_in, features} } and
// gets back { range, display }, where `display` is ready-to-render text
// and `range` is the raw numbers if the UI wants to build its own layout.
//
// Deploy:   supabase functions deploy pricing
// Secrets:  supabase secrets set SERPAPI_KEY=<required, from serpapi.com>
//           supabase secrets set SF_OPEN_DATA_APP_TOKEN=<optional, raises rate limit>
// Tables:   supabase/migrations/*_permit_cache.sql, *_materials_cache.sql
//           (run via `supabase db push`)
//
// Both permit and material lookups are cached in Postgres for 24h — Edge
// Functions are stateless per invocation, so an in-memory cache (fine in a
// long-running Node server) wouldn't survive between requests here. Same
// pattern as the `search` function's search_cache table. Material lookups
// cost SerpApi quota, so the cache also caps spend the same way the
// search_cache table caps Google Places spend.

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  buildLocalRange,
  buildPermitOnlyRange,
  calculateMaterialFloor,
  calculatePermitRange,
  fetchMaterialFloorRaw,
  fetchSFPermitsRaw,
  formatDisplayText,
  JOB_TYPE_KEYWORDS,
  type InsufficientDataResult,
  type JobScope,
  type LocalRange,
  type Material,
  type Permit,
} from "./pricingEngine.ts";

const SERPAPI_KEY = Deno.env.get("SERPAPI_KEY") ?? "";
const SF_OPEN_DATA_APP_TOKEN = Deno.env.get("SF_OPEN_DATA_APP_TOKEN") ?? "";
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Service-role client bypasses RLS to read/write the cache. Nil if env missing —
// caching is then skipped and the function still queries live (best-effort).
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const MONTHS = 6;
const TTL_MS = 24 * 60 * 60 * 1000; // reuse a cached permit/material pull for a day

function json(payload: unknown, status = 200, cache = "bypass"): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", "x-cache": cache },
  });
}

function permitCacheKey(jobKeywords: string[], months: number): string {
  return `${months}:${[...jobKeywords].sort().join("|").toLowerCase()}`;
}

async function fetchSFPermitsCached(
  jobKeywords: string[],
  months: number,
): Promise<{ permits: Permit[]; cache: "hit" | "miss" | "bypass" }> {
  const key = permitCacheKey(jobKeywords, months);

  if (db) {
    try {
      const { data } = await db.from("permit_cache")
        .select("permits, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        return { permits: data.permits as Permit[], cache: "hit" };
      }
    } catch (_) { /* ignore, fall through to a live fetch */ }
  }

  let permits: Permit[];
  try {
    permits = await fetchSFPermitsRaw(jobKeywords, months, SF_OPEN_DATA_APP_TOKEN || undefined);
  } catch (err) {
    console.error("pricing: failed to fetch SF permit data", err);
    return { permits: [], cache: "bypass" };
  }

  if (db) {
    try {
      await db.from("permit_cache").upsert({
        cache_key: key,
        permits,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore, cache write is best-effort */ }
  }

  return { permits, cache: db ? "miss" : "bypass" };
}

function materialsCacheKey(scope: JobScope): string {
  return `${scope.job_type}:${scope.width_in}`;
}

async function fetchMaterialsCached(
  scope: JobScope,
): Promise<{ materials: Material[] | null; cache: "hit" | "miss" | "bypass" }> {
  const key = materialsCacheKey(scope);

  if (db) {
    try {
      const { data } = await db.from("materials_cache")
        .select("materials, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        return { materials: data.materials as Material[], cache: "hit" };
      }
    } catch (_) { /* ignore, fall through to a live fetch */ }
  }

  let materials: Material[] | null;
  try {
    materials = await fetchMaterialFloorRaw(scope, SERPAPI_KEY);
  } catch (err) {
    console.error("pricing: failed to fetch material pricing", err);
    return { materials: null, cache: "bypass" };
  }

  if (materials && db) {
    try {
      await db.from("materials_cache").upsert({
        cache_key: key,
        materials,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore, cache write is best-effort */ }
  }

  return { materials, cache: materials && db ? "miss" : "bypass" };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const job_type = payload.job_type;
  const scope = payload.scope as JobScope | undefined;

  if (
    typeof job_type !== "string" || job_type.length === 0 ||
    !scope || typeof scope.job_type !== "string" || typeof scope.width_in !== "number"
  ) {
    return json({ error: "missing job_type / scope" }, 400);
  }

  const keywords = JOB_TYPE_KEYWORDS[job_type] ?? [job_type];
  const [{ permits, cache: permitCache }, { materials, cache: materialCache }] = await Promise.all([
    fetchSFPermitsCached(keywords, MONTHS),
    fetchMaterialsCached(scope),
  ]);
  const cache = permitCache === "hit" && materialCache === "hit" ? "hit" : "miss";

  const permitRange = calculatePermitRange(permits, scope);
  if (!permitRange) {
    const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
    return json({ range: result, display: formatDisplayText(result) }, 200, cache);
  }

  const materialFloor = materials ? calculateMaterialFloor(materials, scope) : null;
  if (materialFloor === null) {
    // Real permit data exists but materials pricing doesn't (no SERPAPI_KEY
    // yet, or this category has no material lookup) — show the permit-only
    // range instead of throwing the permit data away as "insufficient".
    const result = buildPermitOnlyRange(permitRange);
    return json({ range: result, display: formatDisplayText(result) }, 200, cache);
  }

  const range: LocalRange = buildLocalRange(permitRange, materialFloor);
  return json({ range, display: formatDisplayText(range) }, 200, cache);
});
