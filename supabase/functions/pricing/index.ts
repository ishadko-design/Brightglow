// Supabase Edge Function: `pricing`
//
// Nationwide, all-category "Local cost estimate" — EstimationPro's EPCI API
// (estimationpro.ai/api/v1, BLS wage + PPI backed, free/self-serve) is the
// sole data source across the app's 10 categories. SF DBI permit data was
// removed from the formula entirely 2026-07-06 (originally the primary
// source, then demoted to a cross-check): permit valuations are
// self-reported and unreliable — e.g. $8,754-$48,197 for a water heater,
// verified live 2026-07-03. The permit-matching code stays in
// pricingEngine.ts for reference/tests but nothing here calls it.
//
// The app POSTs { category, description, zip } and gets back
// { range: {all_in_low, all_in_high, confidence, label, data_points} } or
// { range: {error, fallback} } when EPCI has no data (always true for
// Mold & Pest Control — EPCI has no pest-control trade).
//
// Deploy:   supabase functions deploy pricing
// Secrets:  supabase secrets set EPCI_ENABLED=true   <- flip only once
//           EstimationPro confirms commercial licensing terms (their API
//           responses currently say "Free for non-commercial use with
//           attribution"); defaults to false/unset so nothing ships against
//           unclear terms. The API itself needs no key.
//           supabase secrets set ANTHROPIC_API_KEY=<optional — enables the LLM
//           fallback classifier (llmClassifier.ts) for phrasings the keyword
//           matcher misses; unset, keyword matching alone decides>
// Tables:   supabase/migrations/*_epci_cache.sql,
//           *_classification_cache.sql (run via `supabase db push`)

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  buildClassifierPool,
  classifyWithLLM,
} from "./llmClassifier.ts";
import {
  calculateComposedRange,
  CATEGORY_GENERAL,
  classifyJobType,
  detectScopeAddOns,
  fetchEPCIRaw,
  JOB_TYPE_TAXONOMY,
  resolveJobComponents,
  resolveQuantity,
  type EPCIItem,
  type InsufficientDataResult,
} from "./pricingEngine.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EPCI_ENABLED = (Deno.env.get("EPCI_ENABLED") ?? "").toLowerCase() === "true";
// Service-role client bypasses RLS to read/write the cache. Nil if env missing —
// caching is then skipped and the function still queries live (best-effort).
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const TTL_MS = 24 * 60 * 60 * 1000; // reuse a cached EPCI pull for a day

function json(payload: unknown, status = 200, cache = "bypass"): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", "x-cache": cache },
  });
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

function classificationCacheKey(category: string, description: string): string {
  const norm = description.toLowerCase().replace(/\s+/g, " ").trim();
  return `${category}:${norm}`.slice(0, 300);
}

/** LLM fallback classification with a 24h cache. Returns a taxonomy job_type
 *  or null ("none"/failure — the keyword result stands). "none" outcomes are
 *  cached like hits so unmatchable text costs one call, not one per retry. */
async function classifyLLMCached(
  category: string,
  description: string,
): Promise<string | null> {
  const key = classificationCacheKey(category, description);

  if (db) {
    try {
      const { data } = await db.from("classification_cache")
        .select("job_type, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        return data.job_type as string | null;
      }
    } catch (_) { /* ignore, fall through to a live call */ }
  }

  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, category);
  let jobType: string | null;
  try {
    jobType = await classifyWithLLM(pool, description, ANTHROPIC_API_KEY);
  } catch (err) {
    // Not cached: a transient API failure shouldn't pin "no match" for 24h.
    console.error("pricing: LLM classification failed", err);
    return null;
  }
  console.log("pricing: llm-classified", JSON.stringify({ category, description, jobType }));

  if (db) {
    try {
      await db.from("classification_cache").upsert({
        cache_key: key,
        job_type: jobType,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore, cache write is best-effort */ }
  }

  return jobType;
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

  // Either is enough: a category chip alone prices via the category-general
  // entry; a bare typed description (the common search path — the client
  // can't recover a category from a phrase) classifies server-side from
  // job keywords / category stems.
  if (typeof category !== "string" || (category.length === 0 && description.length === 0)) {
    return json({ error: "missing category and description" }, 400);
  }

  // The description already carries any photo-derived detail text (the
  // client appends it before sending — see PricingService.swift), so there's
  // no separate photo_attributes field to classify against.
  let entry = classifyJobType(category, description);

  // LLM classification for every real typed description — primary, not just
  // a fallback for keyword misses. Keywords alone are confidently wrong on
  // typos ("frech door windows" matched "window" and priced 2 vinyl windows
  // instead of a french door pair) and on incidental words ("backyard" →
  // Landscaping), and a wrong specific match never looked like a miss. The
  // model is enum-constrained to the taxonomy (see llmClassifier.ts) — it
  // picks a job type, never a price — and "none"/failure means the keyword
  // result stands. Unique phrasings are cached 24h, so the added call is
  // one-time per phrasing, not per request.
  const trimmedDesc = description.trim();
  if (ANTHROPIC_API_KEY && trimmedDesc.length >= 8) {
    const llmJobType = await classifyLLMCached(category, trimmedDesc);
    if (llmJobType) {
      const generalEntries = Object.values(CATEGORY_GENERAL)
        .filter((e): e is NonNullable<typeof e> => e !== null);
      entry = [...JOB_TYPE_TAXONOMY, ...generalEntries]
        .find((e) => e.job_type === llmJobType) ?? entry;
    }
  }
  if (entry) {
    console.log("pricing: classified", JSON.stringify({ category, description, job_type: entry.job_type }));
  }

  if (!entry) {
    // The backlog for the mapping layer: every description that reached us
    // and classified to nothing (visible in `supabase functions logs pricing`).
    console.log("pricing: unclassified", JSON.stringify({ category, description }));
    const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
    return json({ range: result, display: `${result.error}. ${result.fallback}.` });
  }

  const { quantity, isDefaulted } = resolveQuantity(entry, description);
  const isGeneral = entry.keywords.length === 0;

  // Cross-trade companion items (e.g. a vanity's countertop + faucet) need
  // their own trades fetched alongside the job's own trade.
  const componentTrades = [...new Set(resolveJobComponents(entry.job_type, description).map((c) => c.trade))];
  const tradesToFetch = EPCI_ENABLED ? [entry.trade, ...componentTrades] : [];
  const fetched = await Promise.all(tradesToFetch.map((trade) => fetchEPCICached(trade, zip)));
  const itemsByTrade: Record<string, EPCIItem[]> = {};
  tradesToFetch.forEach((trade, i) => {
    if (fetched[i].items) itemsByTrade[trade] = fetched[i].items!;
  });
  const epciCache = tradesToFetch.length > 0 && fetched.every((f) => f.cache === "hit") ? "hit" : "miss";

  // Scope add-ons the description asserts (tear-out, subfloor…) — usually
  // put there by the clarify chat's canonical details.
  const addOns = detectScopeAddOns(entry, description);
  const epciRange = itemsByTrade[entry.trade]
    ? calculateComposedRange(itemsByTrade, entry, quantity, description, addOns.map((a) => a.itemId))
    : null;

  if (epciRange) {
    const confidence: "high" | "med" | "low" = isGeneral || isDefaulted ? "low" : "med";
    // entry.category, not the request's category — the latter is empty when
    // the job was classified from the description alone.
    let label = isGeneral
      ? `Regional avg for ${entry.category} (EstimationPro)`
      : "Regional avg (EstimationPro)";
    const includedLabels = [...addOns.map((a) => a.label), ...epciRange.includedLabels];
    if (includedLabels.length > 0) {
      label += ` — incl. ${includedLabels.join(", ")}`;
    }

    return json({
      range: {
        all_in_low: epciRange.all_in_low,
        all_in_high: epciRange.all_in_high,
        all_in_typical: epciRange.all_in_typical,
        confidence,
        label,
        data_points: 0,
      },
    }, 200, epciCache);
  }

  // EPCI unavailable (disabled pending licensing, or a transient failure) —
  // no fallback source: SF permit data was removed from the formula
  // entirely (unreliable self-reported valuations), so the honest answer
  // is no number at all.
  const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
  return json({ range: result, display: `${result.error}. ${result.fallback}.` });
});
