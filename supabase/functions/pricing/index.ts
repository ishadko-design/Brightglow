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
  type ClassifiedJob,
  type Classification,
} from "./llmClassifier.ts";
import {
  applyServiceMinimum,
  combineSizeScope,
  computeInHouseItems,
  qualityTier,
  sizeScale,
  windowScopeScale,
} from "./inHouseEngine.ts";
import {
  calculateComposedRange,
  CATEGORY_GENERAL,
  AUTO_CATEGORIES,
  classifyWithCategoryFallback,
  detectScopeAddOns,
  detectVehicle,
  fetchEPCIRaw,
  JOB_TYPE_TAXONOMY,
  resolveJobComponents,
  resolveQuantity,
  stripVehicleWords,
  type EPCIItem,
  type InsufficientDataResult,
  type JobTypeEntry,
} from "./pricingEngine.ts";
import { estimateInHouse, estimateJobsInHouse, type JobScope } from "./estimatePipeline.ts";
import { groundedBand, type GroundedKind } from "./groundedEstimate.ts";

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

/** Semantic classification with a 24h cache. Returns the taxonomy job types
 *  (one per distinct job in the request — see llmClassifier.ts) AND the
 *  vehicle, all from one call. Empty jobs mean "keyword result stands" — the
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
        .select("job_type, jobs, vehicle, vertical, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < TTL_MS) {
        const v = data.vehicle;
        const vert = data.vertical;
        // New shape (jobs JSON) wins; pre-multi-job rows carry one job_type.
        const jobs: ClassifiedJob[] = Array.isArray(data.jobs)
          ? (data.jobs as ClassifiedJob[]).filter((j) => j && typeof j.jobType === "string")
          : typeof data.job_type === "string" && data.job_type
          ? [{ jobType: data.job_type as string, detail: "" }]
          : [];
        return {
          jobs,
          vehicle: v === "auto" || v === "moto" ? v : null,
          vertical: vert === "home" || vert === "auto" ? vert : null,
        };
      }
    } catch (_) { /* ignore, fall through to a live call */ }
  }

  // The pool is the WHOLE taxonomy, not the tapped category's slice: a request
  // can span trades ("repair the siding and fix the roof"), and filtering to
  // the category silently dropped every cross-trade job (2026-09-11 — the
  // siding half of a siding+roof request priced $0). The tapped category
  // travels as a prompt hint instead.
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "");
  let result: Classification;
  try {
    result = await classifyWithLLM(pool, description, ANTHROPIC_API_KEY, category || undefined);
  } catch (err) {
    // Not cached: a transient API failure shouldn't pin "no match" for 24h.
    console.error("pricing: LLM classification failed", err);
    return { jobs: [], vehicle: null, vertical: null };
  }
  console.log("pricing: llm-classified", JSON.stringify({ category, description, ...result }));

  if (db) {
    try {
      await db.from("classification_cache").upsert({
        cache_key: key,
        job_type: result.jobs[0]?.jobType ?? null,
        jobs: result.jobs,
        vehicle: result.vehicle,
        vertical: result.vertical,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore, cache write is best-effort */ }
  }

  return result;
}

const GROUNDED_TTL_MS = 7 * 24 * 60 * 60 * 1000; // remodel costs move slowly

function groundedCacheKey(zip: string | undefined, kind: GroundedKind, description: string): string {
  const norm = description.toLowerCase().replace(/\s+/g, " ").trim();
  // Kind is in the key: "replace tires" grounds differently for a car (4) than
  // a motorcycle (2), so the two must not share a cached band.
  return `${zip ?? "us"}:${kind}:${norm}`.slice(0, 300);
}

/** Web-search-grounded band for jobs the catalog doesn't model, with a 7-day
 *  cache. Returns null when the model declined / the guardrail rejected the
 *  band — the caller then keeps the honest "get 3 bids" decline. A miss is not
 *  cached (a transient search failure shouldn't pin "no estimate" for a week);
 *  a hit is, because the grounded call is the function's most expensive path. */
async function groundedCached(
  zip: string | undefined,
  kind: GroundedKind,
  description: string,
): Promise<{ low: number; typical: number; high: number; basis: string } | null> {
  const key = groundedCacheKey(zip, kind, description);
  if (db) {
    try {
      const { data } = await db.from("grounded_estimate_cache")
        .select("low, typical, high, basis, created_at").eq("cache_key", key).maybeSingle();
      if (data && Date.now() - new Date(data.created_at as string).getTime() < GROUNDED_TTL_MS) {
        return {
          low: Number(data.low),
          typical: Number(data.typical),
          high: Number(data.high),
          basis: typeof data.basis === "string" ? data.basis : "",
        };
      }
    } catch (_) { /* fall through to a live call */ }
  }

  const locationLabel = zip ? `the ${zip} ZIP code area (US)` : "the United States";
  const band = await groundedBand(description, locationLabel, ANTHROPIC_API_KEY, kind);
  if (!band) return null;
  console.log("pricing: grounded-estimated", JSON.stringify({ zip, description, ...band }));

  if (db) {
    try {
      await db.from("grounded_estimate_cache").upsert({
        cache_key: key,
        low: band.low,
        typical: band.typical,
        high: band.high,
        basis: band.basis,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* best-effort cache write */ }
  }
  return band;
}

/** The LLM's per-job detail must be grounded in the request: non-empty and
 *  sharing at least two significant words with it. A hallucinated scope would
 *  price numbers the user never stated; when the detail fails this check the
 *  job falls back to the full description (the pre-multi-job behavior). */
// Big-scope project phrasings that are groundable even when terse. A bare
// "kitchen remodel" (15 chars) falls under the 20-char grounding gate below,
// but unlike a short vague "fix my roof" it has a well-documented cost ballpark
// — so these keywords are let through so a remodel always shows a number
// (reported 2026-09-19: kitchen remodel returned no price). Mirrors
// BIG_SCOPE_SIGNALS in pricingEngine.ts.
const BROAD_PROJECT_WORDS = [
  "remodel", "renovation", "renovate", "addition", "adu", "accessory dwelling",
  "full gut", "gut ", "rebuild", "reconstruct", "whole house", "whole-house",
];
function isBroadProject(description: string): boolean {
  const d = description.toLowerCase();
  return BROAD_PROJECT_WORDS.some((w) => d.includes(w));
}

function validJobDetail(detail: string, description: string): boolean {
  const d = detail.trim();
  if (d.length < 8) return false;
  const sig = (s: string) =>
    new Set(s.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 3));
  const dw = sig(d);
  const sw = sig(description);
  let shared = 0;
  for (const w of dw) {
    if (sw.has(w) && ++shared >= 2) return true;
  }
  return false;
}

/** Web-search-grounded band as a JSON Response, or null when grounding is not
 *  attempted (short/vague, non-broad, no key) or the model declined. Shared by
 *  BOTH decline paths — the unclassified early-out AND the classified-but-
 *  unpriceable path — so a broad project ("kitchen remodel") that classifies to
 *  nothing still gets a ballpark instead of a blank "get bids". */
async function groundedResponse(
  zip: string | undefined,
  kind: GroundedKind,
  trimmedDesc: string,
): Promise<Response | null> {
  if (!ANTHROPIC_API_KEY) return null;
  // Gated to substantial descriptions (a short vague "fix my roof" would only
  // buy a useless wide band at real API cost) — EXCEPT broad-project phrasings
  // ("kitchen remodel"), which have a real ballpark even when terse.
  if (!(trimmedDesc.length >= 20 || isBroadProject(trimmedDesc))) return null;
  const band = await groundedCached(zip, kind, trimmedDesc);
  if (!band) return null;
  return json({
    range: {
      all_in_low: band.low,
      all_in_high: band.high,
      all_in_typical: band.typical,
      confidence: "low",
      label: band.basis
        ? `Estimated from current local prices — ${band.basis}. Confirm with bids.`
        : "Estimated from current local prices. Confirm with bids.",
      grounded: true,
      data_points: 0,
    },
  }, 200, "grounded");
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
  // Wrong-category requests get a second chance without the category before
  // the LLM runs: "replace the dishwasher" under HVAC, a downspout repair
  // under Plumbing, a door repair under Electrical. Only fires when the
  // categorized result is general/null (would otherwise decline), and only
  // ever returns a specific entry — see classifyWithCategoryFallback.
  let entry = classifyWithCategoryFallback(category, classifyText, [], keywordVehicle);

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
  // Multi-job: the classifier may return several jobs, each validated and
  // priced separately below. Empty = "none", the keyword result stands.
  let llmJobs: Array<{ entry: JobTypeEntry; description: string; scope: JobScope }> = [];
  if (ANTHROPIC_API_KEY && trimmedDesc.length >= 3) {
    const llm = await classifyLLMCached(category, trimmedDesc);
    const generalEntries = Object.values(CATEGORY_GENERAL)
      .filter((e): e is NonNullable<typeof e> => e !== null);
    const universe = [...JOB_TYPE_TAXONOMY, ...generalEntries];
    const seen = new Set<string>();
    for (const job of llm.jobs) {
      if (!job.jobType || seen.has(job.jobType)) continue;
      const picked = universe.find((e) => e.job_type === job.jobType);
      if (!picked) continue;
      // A general entry ("some other carpentry work") is not a job — pricing
      // it would be a guess, and letting it through would poison the sum via
      // decline-all. The prompt tells the model to omit unclassifiable parts;
      // this enforces it when the model doesn't.
      if (picked.keywords.length === 0) continue;
      // notIfContains is a hard veto on the entry, not a keyword-matcher
      // tiebreak — the model picks "install solar" for "solar panel repair"
      // just as readily as the keywords did, and that entry prices a whole
      // 20-panel array. Vetoed jobs are dropped, not priced.
      const detail = validJobDetail(job.detail, trimmedDesc) ? job.detail.trim() : trimmedDesc;
      const vetoed = picked.notIfContains?.some((w) =>
        detail.toLowerCase().includes(w)
      );
      if (vetoed) continue;
      seen.add(job.jobType);
      llmJobs.push({
        entry: picked,
        description: detail,
        scope: { quantity: job.quantity, areaSqFt: job.areaSqFt, tier: job.tier },
      });
    }
    // One LLM job keeps the exact historical path: entry override, full
    // description. Only genuinely multi-job requests take the new path.
    if (llmJobs.length === 1) entry = llmJobs[0].entry;
    llmVehicle = llm.vehicle;
    llmVertical = llm.vertical;
  }
  if (llmJobs.length > 1) {
    console.log("pricing: classified multi", JSON.stringify({
      category,
      description,
      jobs: llmJobs.map((j) => ({ job_type: j.entry.job_type, detail: j.description })),
    }));
  } else if (entry) {
    console.log("pricing: classified", JSON.stringify({ category, description, job_type: entry.job_type }));
  }

  // A multi-job LLM result stands on its own — the keyword layer finding
  // nothing must not veto it.
  if (llmJobs.length <= 1 && !entry) {
    // The backlog for the mapping layer: every description that reached us
    // and classified to nothing (visible in `supabase functions logs pricing`).
    console.log("pricing: unclassified", JSON.stringify({ category, description }));
    // Before declining, try the grounded fallback — a broad project like
    // "kitchen remodel" classifies to NOTHING (it isn't in the anchored
    // taxonomy), so without this it returned a blank "get bids" and no price
    // ever showed (reported 2026-09-19). Kind is resolved from the app filter /
    // model / category the same way the classified path does it below.
    const earlyVehicle = vehicle ?? llmVehicle ?? keywordVehicle;
    const earlyVertical = (typeof category === "string" && category
      ? (AUTO_CATEGORIES.has(category) ? "auto" : "home")
      : null) ?? llmVertical;
    const earlyKind: GroundedKind = earlyVehicle === "moto"
      ? "moto"
      : earlyVertical === "auto"
      ? "auto"
      : "home";
    const grounded = await groundedResponse(zip, earlyKind, trimmedDesc);
    if (grounded) return grounded;
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
    // Multi-job requests price each job separately and sum (see
    // estimateJobsInHouse); anything else keeps the historical single path.
    const r = llmJobs.length > 1
      ? estimateJobsInHouse(llmJobs, {
        category,
        zip,
        vehicle: vehicleResolved,
        vertical: verticalResolved,
      })
      : estimateInHouse({
        category,
        description,
        zip,
        vehicle: vehicleResolved,
        vertical: verticalResolved,
        entryOverride: entry,
        // A single LLM job carries its structured scope; a keyword-only entry
        // (no LLM job) has none, and the prose parsers run as before.
        scope: llmJobs.length === 1 ? llmJobs[0].scope : null,
      });
    if (r.kind === "insufficient") {
      console.log(`pricing: ${r.reason}`, JSON.stringify({ category, description, job_type: r.entry?.job_type ?? null }));
      // Coverage tier of last resort: the catalog doesn't model this job (whole-
      // room remodels, and the long tail of auto/moto work), so instead of a
      // blank decline, try a web-search-grounded band. This only runs when the
      // modelled path produced NOTHING — an auto job with a labor-only figure
      // returned "labor" above and never reaches here, so grounding never
      // competes with it. Gated to substantial descriptions (a short/vague
      // "fix my roof" would only produce a useless wide band at real cost).
      // Vehicle-aware so a car job isn't priced as home work. Shown as a
      // low-confidence estimate; failure keeps the honest decline.
      const groundedKind: GroundedKind = vehicleResolved === "moto"
        ? "moto"
        : verticalResolved === "auto"
        ? "auto"
        : "home";
      const grounded = await groundedResponse(zip, groundedKind, trimmedDesc);
      if (grounded) return grounded;
      const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
      return json({ range: result, display: `${result.error}. ${result.fallback}.` });
    }
    if (r.kind === "labor") {
      console.log("pricing: labor-only", JSON.stringify({ category, description, trade: r.entry.trade, typical: r.typical }));
      return json({
        range: {
          all_in_low: r.low,
          all_in_high: r.high,
          all_in_typical: r.typical,
          confidence: "low",
          label: r.label,
          labor_only: true,
          data_points: 0,
        },
      }, 200, "inhouse");
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
    // The labor-only pilot that used to live here moved into estimatePipeline,
    // where it is gated to Auto & moto. EPCI is a home-cost dataset, so an
    // unmodelled job on this branch has no labor fallback at all.
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
