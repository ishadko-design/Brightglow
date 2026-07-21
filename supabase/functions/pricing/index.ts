// Supabase Edge Function: `pricing`
//
// Nationwide, all-category "Local cost estimate" from one of two sources
// behind the same EPCIItem[] interface:
//   - default: the in-house model (inHouseEngine.ts) — BLS OEWS state wages
//     × burden + curated materials baselines (costCatalog.ts). Pure compute,
//     no network, no cache table.
//   - EPCI_ENABLED=true: EstimationPro's EPCI API (estimationpro.ai/api/v1),
//     switched on only if their commercial licensing is ever confirmed.
// SF DBI permit data was removed from the formula entirely 2026-07-06
// (originally the primary source, then demoted to a cross-check): permit
// valuations are self-reported and unreliable — e.g. $8,754-$48,197 for a
// water heater, verified live 2026-07-03. The permit-matching code stays in
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
  type Classification,
} from "./llmClassifier.ts";
import {
  applyServiceMinimum,
  combineSizeScope,
  computeInHouseItems,
  laborOnlyEstimate,
  qualityTier,
  sizeScale,
  windowScopeScale,
} from "./inHouseEngine.ts";
import {
  calculateComposedRange,
  CATEGORY_GENERAL,
  AUTO_CATEGORIES,
  classifyJobType,
  detectScopeAddOns,
  detectVehicle,
  fetchEPCIRaw,
  JOB_TYPE_TAXONOMY,
  resolveJobComponents,
  resolveQuantity,
  stripVehicleWords,
  type EPCIItem,
  type InsufficientDataResult,
} from "./pricingEngine.ts";
import { estimateInHouse } from "./estimatePipeline.ts";

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

/** Semantic classification with a 24h cache. Returns the taxonomy job_type AND
 *  the vehicle, both from one call. Nulls mean "keyword result stands" — the
 *  classifier degrades, never hard-fails. "none" outcomes are cached like hits
 *  so unmatchable text costs one call, not one per retry. */
async function classifyLLMCached(
  category: string,
  description: string,
): Promise<Classification> {
  const key = classificationCacheKey(category, description);

  if (db) {
    try {
      const { data } = await db.from("classification_cache")
        .select("job_type, vehicle, vertical, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        const v = data.vehicle;
        const vert = data.vertical;
        return {
          jobType: data.job_type as string | null,
          vehicle: v === "auto" || v === "moto" ? v : null,
          vertical: vert === "home" || vert === "auto" ? vert : null,
        };
      }
    } catch (_) { /* ignore, fall through to a live call */ }
  }

  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, category);
  let result: Classification;
  try {
    result = await classifyWithLLM(pool, description, ANTHROPIC_API_KEY);
  } catch (err) {
    // Not cached: a transient API failure shouldn't pin "no match" for 24h.
    console.error("pricing: LLM classification failed", err);
    return { jobType: null, vehicle: null, vertical: null };
  }
  console.log("pricing: llm-classified", JSON.stringify({ category, description, ...result }));

  if (db) {
    try {
      await db.from("classification_cache").upsert({
        cache_key: key,
        job_type: result.jobType,
        vehicle: result.vehicle,
        vertical: result.vertical,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore, cache write is best-effort */ }
  }

  return result;
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
  // Auto & moto: the app's vehicle filter. "replace tires" is the same phrase
  // for a car (4 units) and a bike (2, different parts and labor), so this is
  // not recoverable from the description — see MOTO_VARIANTS in pricingEngine.
  const vehicle = payload.vehicle === "moto" ? "moto" : payload.vehicle === "auto" ? "auto" : null;

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
  // Vehicle-aware: for a motorcycle the vehicle noun is stripped before
  // keyword matching, so "replace motorcycle tires" matches the same
  // "replace tires" keyword a car request would (it previously matched
  // nothing and fell through to a labor-only figure).
  // Keyword vehicle detection, used only to make the KEYWORD classification
  // below work on moto phrasings. The authoritative vehicle is resolved after
  // the model has spoken (see vehicleResolved further down): an explicit app
  // filter first, then the model, then this word list as a last resort.
  const keywordVehicle = vehicle ?? detectVehicle(description);
  const classifyText = keywordVehicle === "moto" ? stripVehicleWords(description) : description;
  let entry = classifyJobType(category, classifyText);

  // LLM classification for every real typed description — primary, not just
  // a fallback for keyword misses. Keywords alone are confidently wrong on
  // typos ("frech door windows" matched "window" and priced 2 vinyl windows
  // instead of a french door pair) and on incidental words ("backyard" →
  // Landscaping), and a wrong specific match never looked like a miss. The
  // model is enum-constrained to the taxonomy (see llmClassifier.ts) — it
  // picks a job type, never a price — and "none"/failure means the keyword
  // result stands. Unique phrasings are cached 24h, so the added call is
  // one-time per phrasing, not per request.
  // Lowered from 8 to 3 chars: "tires" (5) and "brakes" (6) are exactly the
  // terse phrasings the keyword layer is worst at, and skipping the model
  // there meant the requests most needing semantics never got them.
  const trimmedDesc = description.trim();
  let llmVehicle: "auto" | "moto" | null = null;
  let llmVertical: "home" | "auto" | null = null;
  if (ANTHROPIC_API_KEY && trimmedDesc.length >= 3) {
    const llm = await classifyLLMCached(category, trimmedDesc);
    if (llm.jobType) {
      const generalEntries = Object.values(CATEGORY_GENERAL)
        .filter((e): e is NonNullable<typeof e> => e !== null);
      entry = [...JOB_TYPE_TAXONOMY, ...generalEntries]
        .find((e) => e.job_type === llm.jobType) ?? entry;
    }
    llmVehicle = llm.vehicle;
    llmVertical = llm.vertical;
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

  // Live path: delegate to the shared pipeline, which accuracy.test.ts scores.
  // Everything below this block is the dormant EPCI branch (EPCI_ENABLED),
  // kept intact pending EstimationPro licensing.
  // Precedence: the app's explicit Auto/Moto filter (the user's own choice)
  // beats the model, which beats the word list. The model is what makes
  // "my Ducati needs new tires" and "tires for my bike" price as motorcycles
  // without anyone enumerating marques.
  const vehicleResolved = vehicle ?? llmVehicle ?? keywordVehicle;
  // The app's own category already implies a vertical when it sent one; the
  // model covers the bare-typed-search case the category can't.
  const verticalResolved = (typeof category === "string" && category
    ? (AUTO_CATEGORIES.has(category) ? "auto" : "home")
    : null) ?? llmVertical;

  if (!EPCI_ENABLED) {
    const r = estimateInHouse({
      category,
      description,
      zip,
      vehicle: vehicleResolved,
      vertical: verticalResolved,
      entryOverride: entry,
    });
    if (r.kind === "insufficient") {
      console.log(`pricing: ${r.reason}`, JSON.stringify({ category, description, job_type: r.entry?.job_type ?? null }));
      const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
      return json({ range: result, display: `${result.error}. ${result.fallback}.` });
    }
    return json({
      range: {
        all_in_low: r.low,
        all_in_high: r.high,
        all_in_typical: r.typical,
        confidence: r.confidence,
        label: r.label,
        data_points: 0,
      },
    }, 200, "inhouse");
  }

  const { quantity, isDefaulted } = resolveQuantity(entry, description);
  const isGeneral = entry.keywords.length === 0;

  // The user described a specific job and the best we could do was a
  // category-general bucket — meaning we don't actually model this job. Those
  // buckets carry arbitrary defaults (2 electrician hours vs 200 sq ft of
  // carpentry), so which one the classifier lands on swings the number wildly:
  // live, "install tv" returned $220 one way and $3,476 the other for the same
  // request (2026-07-16). A number we can't stand behind is worse than none —
  // send these to quotes. A bare category browse (no description) still gets
  // its general figure, which is a fair "typical visit for this trade".
  if (isGeneral && trimmedDesc.length >= 3) {
    // PILOT (2026-07-16): rather than nothing, show the half we can compute
    // rigorously — local billed labor — explicitly labelled so it's never
    // mistaken for an all-in price. Parts/materials are excluded, not guessed.
    const labor = EPCI_ENABLED ? null : laborOnlyEstimate(entry.trade, zip);
    if (labor) {
      console.log("pricing: labor-only", JSON.stringify({ category, description, trade: entry.trade, typical: labor.typical }));
      return json({
        range: {
          all_in_low: labor.low,
          all_in_high: labor.high,
          all_in_typical: labor.typical,
          confidence: "low",
          label: `Typical labor only — ~${labor.hoursLow}–${labor.hoursHigh} hrs at ~$${Math.round(labor.hourlyTypical)}/hr locally. Parts extra.`,
          labor_only: true,
          data_points: 0,
        },
      }, 200, "inhouse");
    }
    console.log("pricing: general-fallback suppressed", JSON.stringify({ category, description, job_type: entry.job_type }));
    const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
    return json({ range: result, display: `${result.error}. ${result.fallback}.` });
  }

  // Cross-trade companion items (e.g. a vanity's countertop + faucet) need
  // their own trades fetched alongside the job's own trade.
  const componentTrades = [...new Set(resolveJobComponents(entry.job_type, description).map((c) => c.trade))];
  const tradesToFetch = [entry.trade, ...componentTrades];
  const itemsByTrade: Record<string, EPCIItem[]> = {};
  let cacheHeader = "inhouse";
  let tier: ReturnType<typeof qualityTier> = { factor: 1, tier: null };
  let scope: ReturnType<typeof windowScopeScale> = null;
  if (EPCI_ENABLED) {
    const fetched = await Promise.all(tradesToFetch.map((trade) => fetchEPCICached(trade, zip)));
    tradesToFetch.forEach((trade, i) => {
      if (fetched[i].items) itemsByTrade[trade] = fetched[i].items!;
    });
    cacheHeader = fetched.every((f) => f.cache === "hit") ? "hit" : "miss";
  } else {
    // Grade words ("high-end", "builder-grade") scale materials; stated
    // dimensions ("72x80") scale the measured item off its reference size.
    tier = qualityTier(description);
    // A stated dimension scales the measured item; a stated scope (glass-only
    // vs. full-frame tear-out) is the bigger lever for openings and multiplies
    // on top. Both fold into one SizeScale the item math consumes.
    const size = sizeScale(entry.itemId, description);
    scope = windowScopeScale(entry.itemId, description);
    const sizing = combineSizeScope(entry.itemId, size, scope);
    if (sizing) {
      console.log("pricing: sized", JSON.stringify({ itemId: entry.itemId, description, size, scope }));
    }
    for (const trade of tradesToFetch) {
      itemsByTrade[trade] = computeInHouseItems(trade, zip, tier.factor, sizing);
    }
  }

  // Scope add-ons the description asserts (tear-out, subfloor…) — usually
  // put there by the clarify chat's canonical details.
  const addOns = detectScopeAddOns(entry, description);
  let range = itemsByTrade[entry.trade]
    ? calculateComposedRange(itemsByTrade, entry, quantity, description, addOns.map((a) => a.itemId))
    : null;
  // In-house bands are raw hours×wage math — floor tiny jobs at the trade's
  // service-call minimum. EPCI bands already embed minimum-charge reality.
  if (range && !EPCI_ENABLED) {
    range = applyServiceMinimum(range, entry.trade);
  }

  if (range) {
    const confidence: "high" | "med" | "low" = isGeneral || isDefaulted ? "low" : "med";
    // entry.category, not the request's category — the latter is empty when
    // the job was classified from the description alone. EstimationPro is
    // credited only when their data is actually the source.
    const source = EPCI_ENABLED ? " (EstimationPro)" : "";
    let label = isGeneral
      ? `Regional avg for ${entry.category}${source}`
      : `Regional avg${source}`;
    const includedLabels = [...addOns.map((a) => a.label), ...range.includedLabels];
    if (includedLabels.length > 0) {
      label += ` — incl. ${includedLabels.join(", ")}`;
    }
    // Tell the user the scope signal was heard and priced (the biggest lever
    // for an opening — glass-only vs. a full-frame tear-out).
    if (scope) {
      label += `${includedLabels.length > 0 ? "," : " —"} ${scope.scope}`;
    }
    // Tell the user the grade signal was heard and priced.
    if (tier.tier) {
      label += `${includedLabels.length > 0 || scope ? "," : " —"} ${tier.tier} materials`;
    }

    return json({
      range: {
        all_in_low: range.all_in_low,
        all_in_high: range.all_in_high,
        all_in_typical: range.all_in_typical,
        confidence,
        label,
        data_points: 0,
      },
    }, 200, cacheHeader);
  }

  // No range: an EPCI fetch failed, or the itemId is missing from the
  // source catalog (a bug — costCatalog.test.ts guards in-house coverage).
  // No fallback source: SF permit data was removed from the formula
  // entirely (unreliable self-reported valuations), so the honest answer
  // is no number at all.
  const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
  return json({ range: result, display: `${result.error}. ${result.fallback}.` });
});
