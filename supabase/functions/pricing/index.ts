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
import { canonicalJob, groundedBand, type GroundedKind } from "./groundedEstimate.ts";
import { stateForZip } from "./zipState.ts";
import { ZIP3_CBSA } from "./metroWages.generated.ts";
import { canonicalize, canonicalKey, settleJobType, type CanonicalJob, itemize, type ItemizedEstimate, type ItemizeKind } from "./itemizedEstimate.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EPCI_ENABLED = (Deno.env.get("EPCI_ENABLED") ?? "").toLowerCase() === "true";
// Service-role client bypasses RLS to read/write the cache. Nil if env missing —
// caching is then skipped and the function still queries live (best-effort).
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const TTL_MS = 24 * 60 * 60 * 1000; // reuse a cached EPCI pull for a day
/** A phrasing's job type doesn't change; 30 days (was the 24h EPCI TTL) so a
 *  repeat search never pays the ~8k-token classifier call again. */
const CLASSIFY_TTL_MS = 30 * 24 * 60 * 60 * 1000;

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

/** classification_cache.job_type value marking a "project" classification —
 *  never a real taxonomy id (those are "<trade>.<job>"). */
const PROJECT_SENTINEL = "__project__";

function classificationCacheKey(category: string, description: string): string {
  const norm = description.toLowerCase().replace(/\s+/g, " ").trim();
  // "v2:" — rows written before scope_kind existed carry no project flag, so
  // they must not be served (a cached "task" sauna would keep its bare-circuit
  // price for 24h). Bump again whenever the classifier's output shape changes.
  return `v2:${category}:${norm}`.slice(0, 300);
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
      if (data && Date.now() - new Date(data.created_at as string).getTime() < CLASSIFY_TTL_MS) {
        const v = data.vehicle;
        const vert = data.vertical;
        // New shape (jobs JSON) wins; pre-multi-job rows carry one job_type.
        const jobs: ClassifiedJob[] = Array.isArray(data.jobs)
          ? (data.jobs as ClassifiedJob[]).filter((j) => j && typeof j.jobType === "string")
          : typeof data.job_type === "string" && data.job_type && data.job_type !== PROJECT_SENTINEL
          ? [{ jobType: data.job_type as string, detail: "" }]
          : [];
        return {
          jobs,
          vehicle: v === "auto" || v === "moto" ? v : null,
          vertical: vert === "home" || vert === "auto" ? vert : null,
          // No column for it: the project flag rides in job_type as a sentinel
          // (see the write below) so the cache needs no migration.
          scopeKind: data.job_type === PROJECT_SENTINEL ? "project" : "task",
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
        job_type: result.scopeKind === "project"
          ? PROJECT_SENTINEL
          : result.jobs[0]?.jobType ?? null,
        jobs: result.jobs,
        vehicle: result.vehicle,
        vertical: result.vertical,
        created_at: new Date().toISOString(),
      });
    } catch (_) { /* ignore, cache write is best-effort */ }
  }

  return result;
}

const GROUNDED_TTL_MS = 30 * 24 * 60 * 60 * 1000; // remodel costs move slowly (was 7 days)

function groundedCacheKey(zip: string | undefined, kind: GroundedKind, description: string): string {
  // Canonical key when we recognize the job; else the normalized full text.
  const base = canonicalJob(description) ??
    description.toLowerCase().replace(/\s+/g, " ").trim();
  // Kind is in the key: "replace tires" grounds differently for a car (4) than
  // a motorcycle (2), so the two must not share a cached band.
  // "g2:" — bands cached before the install-excludes-the-unit and
  // price-every-component rules (2026-09-30) must not be served for 7 days.
  // Region is the metro (see `area`), not the exact ZIP: same market, one band.
  return `g3:${area(zip)}:${kind}:${base}`.slice(0, 300);
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
  city?: string,
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

  const locationLabel = placeLabel(zip, city);
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

// Whole-PROPERTY scope: a gut/structural/whole-house job, an addition, an ADU,
// or a new build. Unlike a room remodel ("kitchen remodel" — which isn't in the
// priced taxonomy and already declines to grounding), the LLM classifier can
// map these onto a narrow single-trade entry that DOES price (framing, drywall,
// repipe), so the modelled path emits a tiny task figure instead of declining —
// live 2026-09-19: "Full structural renovation house 1200 sqft" showed
// $98–$430. These are never one modeled task; they always route to the grounded
// whole-project ballpark, overriding whatever single trade classified. Home
// only: Auto & moto has real whole-vehicle entries (full respray, full detail).
const WHOLE_PROJECT_SIGNALS = [
  "whole house", "whole-house", "whole home", "whole-home", "entire house",
  "entire home", "full house", "gut renovation", "gut remodel", "full gut",
  "down to studs", "down to the studs", "studs out", "structural renovation",
  "structural remodel", "full structural", "structural rebuild",
  "house renovation", "home renovation", "full renovation", "full remodel",
  "complete renovation", "complete remodel", "addition", "adu",
  "accessory dwelling", "new construction", "rebuild", "reconstruct",
];
function isWholeProject(description: string): boolean {
  const d = description.toLowerCase();
  return WHOLE_PROJECT_SIGNALS.some((w) => d.includes(w));
}

// The clarify chat marks a multi-component job explicitly in its `details`
// ("project: …; includes: …") — see clarify's PROJECT SCOPE rules. That marker
// is a deterministic signal, independent of the classifier call succeeding.
function hasProjectScope(description: string): boolean {
  return /\bproject:\s*\S/i.test(description) && /\bincludes:\s*\S/i.test(description);
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
// ── AI-first itemized estimate ──────────────────────────────────────────────

/** Kill switch: AI_FIRST_HOME=false turns the AI estimator off. With the
 *  formula retired that means no prices at all, unless FORMULA_FALLBACK=true. */
const AI_FIRST_HOME = (Deno.env.get("AI_FIRST_HOME") ?? "true") !== "false";
/** Emergency switch only: FORMULA_FALLBACK=true lets the catalog formula answer
 *  when the AI can't. Off by default — the formula is retired from serving. */
const FORMULA_FALLBACK = (Deno.env.get("FORMULA_FALLBACK") ?? "false") === "true";
// Searched bands are the expensive call (~$0.05-0.12 with web search) and trade
// prices barely move: keep them 180 days (was 30). Product call 2026-10-02:
// "this price usually doesn't change much — cache everything".
const ITEMIZED_TTL_MS = 180 * 24 * 60 * 60 * 1000;   // searched bands
const KNOWLEDGE_TTL_MS = 3 * 24 * 60 * 60 * 1000;   // until the search lands
/** A knowledge band younger than this means its web search is already
 *  running in the background (started by the request that wrote it); don't
 *  start another. Older and still unsearched = that search failed; retry. */
const SEARCH_INFLIGHT_MS = 2 * 60 * 1000;

/** Where the job is, for every AI price prompt. Always local: the city the
 *  app shows (when sent), the ZIP and its state, plus an explicit instruction
 *  not to fall back on national averages. A bare "the 94110 ZIP code area"
 *  left the model to guess the market (2026-10-02). */
function placeLabel(zip: string | undefined, city?: string): string {
  const state = stateForZip(zip);
  const where = [city, zip ? `ZIP ${zip}` : null, state].filter(Boolean).join(", ");
  return where
    ? `${where} (US) — use prices in THIS local market, not national averages`
    : "the United States";
}

/** Cache region for AI bands: the metro when the ZIP is in one, else zip3.
 *  A metro is one labor/price market — the Bay Area alone spans 8 zip3s
 *  (940–949), which used to pay for the same job 8 times. Rural zip3s keep
 *  their own key. */
const area = (zip?: string) => {
  if (!zip || !/^\d{5}$/.test(zip)) return "us";
  const cbsa = ZIP3_CBSA[zip.slice(0, 3)];
  return cbsa ? `m${cbsa}` : zip.slice(0, 3);
};

/** description -> canonical job, cached forever by exact text so a repeated
 *  description never re-rolls its key (search_cache table, "canon2:" rows). */
const canonKey = (description: string) =>
  `canon2:${description.toLowerCase().replace(/\s+/g, " ")}`.slice(0, 300);

/** Cache read only — a DB lookup, no model call. */
async function readCanonical(description: string): Promise<CanonicalJob | null> {
  if (!db) return null;
  try {
    const { data } = await db.from("search_cache").select("response").eq("cache_key", canonKey(description)).maybeSingle();
    const r = data?.response as CanonicalJob | undefined;
    return r?.job ? r : null;
  } catch (_) {
    return null;
  }
}

/** Model call + cache write (only on a read miss). */
async function computeCanonical(description: string): Promise<CanonicalJob | null> {
  const c = await canonicalize(description, ANTHROPIC_API_KEY);
  if (c && db) {
    try {
      await db.from("search_cache").upsert({ cache_key: canonKey(description), response: c, created_at: new Date().toISOString() });
    } catch (_) { /* ignore */ }
  }
  return c;
}

/** Itemized bands live in grounded_estimate_cache ("it2:" keys); the basis
 *  column carries {basis, components, searched} as JSON (no migration). */
async function readItemized(key: string): Promise<(ItemizedEstimate & { ageMs: number }) | null> {
  if (!db) return null;
  try {
    const { data } = await db.from("grounded_estimate_cache")
      .select("low, typical, high, basis, created_at").eq("cache_key", key).maybeSingle();
    if (!data) return null;
    const meta = JSON.parse(String(data.basis ?? "{}"));
    const age = Date.now() - new Date(data.created_at as string).getTime();
    if (age > (meta.searched ? ITEMIZED_TTL_MS : KNOWLEDGE_TTL_MS)) return null;
    return {
      low: Number(data.low), typical: Number(data.typical), high: Number(data.high),
      basis: meta.basis ?? "", components: meta.components ?? [], searched: !!meta.searched,
      ageMs: age,
    };
  } catch (_) {
    return null;
  }
}

async function writeItemized(key: string, e: ItemizedEstimate): Promise<void> {
  if (!db) return;
  try {
    await db.from("grounded_estimate_cache").upsert({
      cache_key: key, low: e.low, typical: e.typical, high: e.high,
      basis: JSON.stringify({ basis: e.basis, components: e.components, searched: e.searched }),
      created_at: new Date().toISOString(),
    });
  } catch (_) { /* ignore */ }
}

/** One line per AI price: the cache key (taxonomy job + bucketed facts + metro
 *  code) and how it was served. No request text or ZIP — the key is all the
 *  pricing-keys workflow reads, and that workflow's log is public. */
function logPriceKey(key: string, cacheState: string, ms: number): void {
  console.log("pricing: price-key " + JSON.stringify({ key, cacheState, ms }));
}

function itemizedJson(e: ItemizedEstimate, cacheState: string): Response {
  return json({
    range: {
      all_in_low: e.low,
      all_in_high: e.high,
      all_in_typical: e.typical,
      confidence: e.searched ? "medium" : "low",
      label: e.basis
        ? `Estimated from ${e.searched ? "current local prices" : "typical local costs"} — ${e.basis}. Confirm with bids.`
        : "Estimated from current local prices. Confirm with bids.",
      grounded: true,
      data_points: 0,
      components: e.components,
      searched: e.searched,
    },
  }, 200, cacheState);
}

/** Fast: cached band, else a knowledge itemization now (the searched one fills
 *  the cache in the background). Full: cached SEARCHED band, else search now
 *  within budget, else the knowledge band. Null -> formula fallback. */
async function itemizedResponse(
  zip: string | undefined, description: string, fast: boolean, kind: ItemizeKind = "home", city?: string,
): Promise<Response | null> {
  const t0 = Date.now();
  const r = await itemizedEstimateFor(zip, description, fast, kind, city);
  if (r) logPriceKey(r.key ?? "", `${fast ? "fast" : "full"}:${r.cacheState}`, Date.now() - t0);
  return r ? itemizedJson(r.estimate, r.cacheState) : null;
}

async function itemizedEstimateFor(
  zip: string | undefined, description: string, fast: boolean, kind: ItemizeKind = "home", city?: string,
): Promise<{ estimate: ItemizedEstimate; cacheState: string; key?: string } | null> {
  const label = placeLabel(zip, city);
  // A phrasing seen before resolves its canonical job from cache (no model
  // call). A new phrasing needs the canonicalize call — and on the fast path
  // the quick price no longer waits for it: both run at once, the quick price
  // from the raw request (2026-10-02, first prices took 10s+). The canonical
  // job still keys the cache, so a hit found once it lands is served instead.
  let canon = await readCanonical(description);
  let speculative: Promise<ItemizedEstimate | null> | null = null;
  if (!canon) {
    speculative = itemize(`Request: ${description}`, label, ANTHROPIC_API_KEY, false, undefined, kind);
    canon = await computeCanonical(description);
  }
  if (!canon) {
    const k = speculative ? await speculative : null;
    return k ? { estimate: k, cacheState: "it-knowledge" } : null;
  }
  canon = settleJobType(canon, hasProjectScope(description) || isWholeProject(description));
  // The job type knows the vehicle better than the request's flags: a
  // motorcycle job filed under kind "auto" (no vehicle on that phase's request)
  // got a second, wrong cache row and a car prompt (2026-10-05, $140–330 for a
  // 16k-mile bike service).
  if (canon.jobType?.startsWith("moto.")) kind = "moto";
  else if (canon.jobType?.startsWith("auto.") && kind === "home") kind = "auto";
  // Kind in the key: "replace tires" is 4 for a car and 2 for a motorcycle.
  // it2: keys are taxonomy job + bucketed facts (see canonicalKey).
  const key = `it2:${area(zip)}:${kind === "home" ? "" : `${kind}:`}${canonicalKey(canon)}`;
  // The canonical form is what gets priced: stable across phrasings, and it
  // carries every price fact. The original text rides along for nuance.
  const priced = `${canon.job}${canon.facts.length ? ` (${canon.facts.join("; ")})` : ""}. Request: ${description}`;
  const cached = await readItemized(key);
  if (cached && (fast || cached.searched)) return { estimate: cached, cacheState: "it-hit", key };

  const searchAndStore = async () => {
    const s = await itemize(priced, label, ANTHROPIC_API_KEY, true, undefined, kind);
    if (s) {
      await writeItemized(key, s);
      console.log("pricing: itemized-searched", JSON.stringify({ key, low: s.low, typical: s.typical, high: s.high }));
    }
    return s;
  };

  if (fast) {
    // The fast phase never starts a web search: the full request (sent with
    // it, and by the chat-finish prefetch) owns that, so one job runs one
    // search, not one per phase.
    const k = await (speculative ?? itemize(priced, label, ANTHROPIC_API_KEY, false, undefined, kind));
    if (!k) return null;
    await writeItemized(key, k);
    return { estimate: k, cacheState: "it-knowledge", key };
  }

  // Never make the user wait on the web search (2026-10-02: 10-23s, "24
  // seconds is unacceptable"). Serve the cached band if any, else a quick
  // knowledge itemization (~4s); the searched band is computed in the
  // background and replaces it in the cache, so the next person asking for
  // this job in this metro gets the searched number instantly.
  if (!cached || cached.ageMs > SEARCH_INFLIGHT_MS) {
    (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } })
      .EdgeRuntime?.waitUntil?.(searchAndStore());
  }
  if (cached) return { estimate: cached, cacheState: "it-hit", key };
  const k = await (speculative ?? itemize(priced, label, ANTHROPIC_API_KEY, false, undefined, kind));
  if (!k) return null;
  await writeItemized(key, k);
  return { estimate: k, cacheState: "it-knowledge", key };
}

async function groundedResponse(
  zip: string | undefined,
  kind: GroundedKind,
  trimmedDesc: string,
  city?: string,
): Promise<Response | null> {
  if (!ANTHROPIC_API_KEY) return null;
  // Gated to substantial descriptions (a short vague "fix my roof" would only
  // buy a useless wide band at real API cost) — EXCEPT broad-project phrasings
  // ("kitchen remodel"), which have a real ballpark even when terse.
  if (!(trimmedDesc.length >= 20 || isBroadProject(trimmedDesc))) return null;
  const band = await groundedCached(zip, kind, trimmedDesc, city);
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
  // The city the app shows ("San Francisco"); newer builds send it. Location
  // context only — the cache stays keyed by zip3.
  const city = typeof payload.city === "string" ? payload.city.trim().slice(0, 80) || undefined : undefined;
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

  const isAutoRequest = !!keywordVehicle || (typeof category === "string" && AUTO_CATEGORIES.has(category));
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
  let llmProject = false;
  // Multi-job: the classifier may return several jobs, each validated and
  // priced separately below. Empty = "none", the keyword result stands.
  let llmJobs: Array<{ entry: JobTypeEntry; description: string; scope: JobScope }> = [];
  // The classifier only feeds the formula (retired from serving) and, here,
  // the car/moto/home kind of the AI estimate. When the app already says the
  // kind — a category from the chat or the Auto/Moto filter — skip it: it was
  // an ~8k-token call (2-4s, up to ~$0.02) on every new phrasing, before the
  // AI price could even start (2026-10-02).
  const kindKnown = vehicle !== null || keywordVehicle !== null ||
    (typeof category === "string" && category.length > 0);
  if (ANTHROPIC_API_KEY && trimmedDesc.length >= 3 && (FORMULA_FALLBACK || !kindKnown)) {
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
    llmProject = llm.scopeKind === "project";
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

  // Route (2026-09-30, measured on the held-out set): the catalog formula is
  // the better estimator for STANDARD jobs it classifies to a specific entry
  // (18/18 in published range, 15% median error vs 13/18, 20% for the AI);
  // the itemized, web-grounded AI is the estimator for everything else —
  // projects, multi-component scopes, long-tail jobs the catalog doesn't know
  // or only matches by a generic entry (a sauna install was priced as a bare
  // circuit). Same rule for cars and motorcycles (2026-09-30: "all should
  // have a price") — and the AI is also the fallback wherever the formula
  // declines or can only give labor (see aiPrice below).
  const aiKind: ItemizeKind = (vehicle ?? llmVehicle ?? keywordVehicle) === "moto"
    ? "moto"
    : (isAutoRequest || llmVertical === "auto") ? "auto" : "home";
  const aiPrice = () =>
    ANTHROPIC_API_KEY && trimmedDesc.length >= 3 && AI_FIRST_HOME
      ? itemizedResponse(zip, trimmedDesc, payload.fast === true, aiKind, city)
      : Promise.resolve(null);
  // AI first, for every job (2026-10-02, product decision). The formula was
  // kept for "standard" jobs on a held-out score — but that set is national
  // aggregator figures, the same family the formula is calibrated to, so the
  // score was circular. In the field the formula kept shipping confident,
  // wrong numbers (a sauna circuit at $240–1.5k, a Thruxton 1200R oil change
  // at $58–160), and one wrong number costs the user's trust for good. The
  // formula now answers only when the AI can't (no key, kill switch, failure).
  {
    const ai = await aiPrice();
    if (ai) return ai;
  }

  // The formula no longer answers users (2026-10-02, product decision: "one
  // response like this and we lose the user forever"). It priced "Patch flat
  // roof" as a $6.4k–17k replacement, a sauna circuit at $240–1.5k and a
  // Thruxton oil change at $58–160 — every time the AI was not consulted. If
  // the itemized AI can't answer, the web-search-grounded AI gets a second
  // try; if that fails too, no price is shown ("Get 3 bids"), never a formula
  // number. FORMULA_FALLBACK=true restores the old fallback as an emergency
  // switch only; the code below stays for the accuracy harness.
  if (!FORMULA_FALLBACK) {
    if (ANTHROPIC_API_KEY && trimmedDesc.length >= 3) {
      const grounded = await groundedResponse(zip, aiKind, trimmedDesc, city);
      if (grounded) return grounded;
    }
    console.log("pricing: no AI price, declining (formula retired)", JSON.stringify({ category, description }));
    const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
    return json({ range: result, display: `${result.error}. ${result.fallback}.` });
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
    const grounded = await groundedResponse(zip, earlyKind, trimmedDesc, city);
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
    // Whole-property scope overrides any single-trade classification: a gut /
    // structural / whole-house reno, an addition, or an ADU is never one
    // modeled task, so hand it straight to the grounded whole-project ballpark
    // rather than let a narrow entry (framing, drywall, repipe) price it as a
    // small job. Home only — auto has real whole-vehicle entries. Falls through
    // to the modeled path only if grounding is unavailable (no key / declined).
    if (
      verticalResolved !== "auto" && vehicleResolved !== "moto" &&
      (llmProject || isWholeProject(trimmedDesc) || hasProjectScope(trimmedDesc))
    ) {
      console.log("pricing: whole-project override", JSON.stringify({ category, description, llmProject }));
      const grounded = await groundedResponse(zip, "home", trimmedDesc, city);
      if (grounded) return grounded;
    }

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
      const aiFallback = await aiPrice();
      if (aiFallback) return aiFallback;
      const grounded = await groundedResponse(zip, groundedKind, trimmedDesc, city);
      if (grounded) return grounded;
      const result: InsufficientDataResult = { error: "Insufficient data", fallback: "Get 3 bids" };
      return json({ range: result, display: `${result.error}. ${result.fallback}.` });
    }
    if (r.kind === "labor") {
      console.log("pricing: labor-only", JSON.stringify({ category, description, trade: r.entry.trade, typical: r.typical }));
      // A labor-only figure isn't a price the user can act on — the AI prices
      // the whole job (parts included); labor-only stays as the fallback.
      const aiAllIn = await aiPrice();
      if (aiAllIn) return aiAllIn;
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
    // (The >3x misclassification guard that used to sit here is gone: the AI
    // now prices every job first, so reaching this line means it couldn't.)
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
