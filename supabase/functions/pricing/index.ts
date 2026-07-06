// Supabase Edge Function: `pricing`
//
// Nationwide, all-category "Local cost estimate" — EstimationPro's EPCI API
// (estimationpro.ai/api/v1, BLS wage + PPI backed, free/self-serve) is the
// primary data source across the app's 10 categories. SF DBI permit data
// (data.sfgov.org) is kept only as a cross-check confidence-booster for the
// 5 job_types it originally covered, never the headline number — permit
// valuations are self-reported and were producing implausible ranges (e.g.
// $8,754-$48,197 for a water heater, verified live 2026-07-03).
//
// The app POSTs { category, description, zip } and gets back
// { range: {all_in_low, all_in_high, confidence, label, data_points} } or
// { range: {error, fallback} } when neither source has data (always true for
// Mold & Pest Control — EPCI has no pest-control trade, same gap permits had).
//
// Deploy:   supabase functions deploy pricing
// Secrets:  supabase secrets set EPCI_ENABLED=true   <- flip only once
//           EstimationPro confirms commercial licensing terms (their API
//           responses currently say "Free for non-commercial use with
//           attribution"); defaults to false/unset so nothing ships against
//           unclear terms. The API itself needs no key.
//           supabase secrets set SF_OPEN_DATA_APP_TOKEN=<optional, raises rate limit>
// Tables:   supabase/migrations/*_permit_cache.sql, *_epci_cache.sql
//           (run via `supabase db push`)

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  calculatePermitRange,
  classifyJobType,
  calculateEPCIRange,
  fetchEPCIRaw,
  fetchSFPermitsRaw,
  JOB_TYPE_KEYWORDS,
  LEGACY_PERMIT_JOB_TYPES,
  rangesOverlap,
  resolveQuantity,
  type EPCIItem,
  type InsufficientDataResult,
  type Permit,
} from "./pricingEngine.ts";

const SF_OPEN_DATA_APP_TOKEN = Deno.env.get("SF_OPEN_DATA_APP_TOKEN") ?? "";
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EPCI_ENABLED = (Deno.env.get("EPCI_ENABLED") ?? "").toLowerCase() === "true";
// Service-role client bypasses RLS to read/write the cache. Nil if env missing —
// caching is then skipped and the function still queries live (best-effort).
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const MONTHS = 6;
const TTL_MS = 24 * 60 * 60 * 1000; // reuse a cached permit/EPCI pull for a day

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

function epciCacheKey(trade: string, zip: string | undefined): string {
  return `${trade}:${zip && zip.length >= 3 ? zip.slice(0, 3) : "national"}`;
}

async function fetchEPCICached(
  trade: string,
  zip: string | undefined,
): Promise<{ items: EPCIItem[] | null; cache: "hit" | "miss" | "bypass" }> {
  const key = epciCacheKey(trade, zip);

  if (db) {
    try {
      const { data } = await db.from("epci_cache")
        .select("items, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        return { items: data.items as EPCIItem[], cache: "hit" };
      }
    } catch (_) { /* ignore, fall through to a live fetch */ }
  }

  let items: EPCIItem[];
  try {
    items = await fetchEPCIRaw(trade, zip);
  } catch (err) {
    console.error("pricing: failed to fetch EstimationPro data", err);
    return { items: null, cache: "bypass" };
  }

  if (db) {
    try {
      await db.from("epci_cache").upsert({
        cache_key: key,
        items,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore, cache write is best-effort */ }
  }

  return { items, cache: db ? "miss" : "bypass" };
}

/** Reuses calculatePermitRange (permits above/pricingEngine.ts) with a fixed
 *  generic width — none of the 5 cross-checked job_types are actually sized
 *  by width, so this only exists to satisfy JobScope's shape (matches the
 *  36in default the client used everywhere before this session). */
function permitRangeFor(jobType: string, permits: Permit[], photoAttributes: string[]) {
  return calculatePermitRange(permits, { job_type: jobType, width_in: 36, features: photoAttributes });
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

  const category = payload.category;
  const description = typeof payload.description === "string" ? payload.description : "";
  const zip = typeof payload.zip === "string" ? payload.zip : undefined;

  if (typeof category !== "string" || category.length === 0) {
    return json({ error: "missing category" }, 400);
  }

  // The description already carries any photo-derived detail text (the
  // client appends it before sending — see PricingService.swift), so there's
  // no separate photo_attributes field to classify against.
  const entry = classifyJobType(category, description);
  if (!entry) {
    const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
    return json({ range: result, display: `${result.error}. ${result.fallback}.` });
  }

  const { quantity, isDefaulted } = resolveQuantity(entry, description);
  const isGeneral = entry.keywords.length === 0;
  const isSF = !!zip && zip.startsWith("941");
  const eligibleForCrossCheck = isSF && LEGACY_PERMIT_JOB_TYPES.has(entry.job_type);

  const { items, cache: epciCache } = EPCI_ENABLED
    ? await fetchEPCICached(entry.trade, zip)
    : { items: null, cache: "bypass" as const };
  const epciRange = items ? calculateEPCIRange(items, entry, quantity) : null;

  if (epciRange) {
    let confidence: "high" | "med" | "low" = isGeneral || isDefaulted ? "low" : "med";
    let label = isGeneral
      ? `Regional avg for ${category} (EstimationPro)`
      : "Regional avg (EstimationPro)";
    let dataPoints = 0;

    if (eligibleForCrossCheck) {
      const { permits } = await fetchSFPermitsCached(JOB_TYPE_KEYWORDS[entry.job_type], MONTHS);
      const permitRange = permitRangeFor(entry.job_type, permits, [description]);
      if (permitRange) {
        const lo = permitRange.p25 * 1.2;
        const hi = permitRange.p75 * 1.2;
        if (rangesOverlap(lo, hi, epciRange.all_in_low, epciRange.all_in_high)) {
          confidence = "high";
          dataPoints = permitRange.count;
          label = `Regional avg — cross-checked against ${permitRange.count} SF permits`;
        }
      }
    }

    return json({
      range: {
        all_in_low: epciRange.all_in_low,
        all_in_high: epciRange.all_in_high,
        confidence,
        label,
        data_points: dataPoints,
      },
    }, 200, epciCache);
  }

  // EPCI unavailable (disabled pending licensing, or a transient failure) —
  // fall back to the legacy SF-permit-only path for the 5 job_types it
  // covers, so those don't regress to nothing while EPCI is gated off.
  if (eligibleForCrossCheck) {
    const { permits, cache: permitCache } = await fetchSFPermitsCached(JOB_TYPE_KEYWORDS[entry.job_type], MONTHS);
    const permitRange = permitRangeFor(entry.job_type, permits, [description]);
    if (permitRange) {
      return json({
        range: {
          all_in_low: permitRange.p25 * 1.2,
          all_in_high: permitRange.p75 * 1.2,
          confidence: permitRange.count > 30 ? "high" : permitRange.count > 10 ? "med" : "low",
          label: `${permitRange.count} SF permits — permit data only`,
          data_points: permitRange.count,
        },
      }, 200, permitCache);
    }
  }

  const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
  return json({ range: result, display: `${result.error}. ${result.fallback}.` });
});
