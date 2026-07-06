// Local All-In Cost Range engine (Deno port).
//
// Blends SF DBI building permit valuations (data.sfgov.org) with retail
// material pricing to produce a defensible cost range for a home-services
// job, instead of a made-up "$100-250" placeholder.
//
// This is a pure port of the Node/Jest-tested version in
// /pricing-engine/src/pricingEngine.ts — same logic, but caching is handled
// by the caller (index.ts, via Postgres) since Edge Functions are stateless
// per invocation and can't rely on an in-memory Map surviving requests.

const SF_PERMITS_ENDPOINT = "https://data.sfgov.org/resource/i98e-djp9.json";
const SF_LABOR_FLOOR = 600;
// City permit valuations are self-reported by filers and are consistently
// lower than what the job actually costs (contractors under-declare to
// reduce permit fees). We correct for that before showing a number.
const PERMIT_VALUATION_BUFFER = 1.2; // valuations are lowballed

export interface Permit {
  contractor: string | null;
  description: string;
  estimated_cost: number;
  filed_date: string;
  completed_date: string | null;
  status: string;
}

export interface NormalizedPermit extends Permit {
  job_type: string;
  size: number | null;
}

export interface JobScope {
  job_type: string;
  width_in: number;
  features: string[];
  /** Postal code from the app's currently selected location, used to resolve
   *  the nearest real Home Depot store for materials pricing (see
   *  `nearestStoreId`). Optional — falls back to a default Bay Area store. */
  zip?: string;
}

export interface Material {
  sku: string;
  name: string;
  price: number;
}

export interface PermitRange {
  p25: number;
  p50: number;
  p75: number;
  count: number;
}

export interface LocalRange {
  materials_included: true;
  material_low: number;
  material_high: number;
  labor_low: number;
  labor_high: number;
  all_in_low: number;
  all_in_high: number;
  data_points: number;
  confidence: "high" | "med" | "low";
  source: string;
}

// Shown when SF permit data is good enough (10+ matches) but materials
// pricing isn't available (no SERPAPI_KEY, or a category with no material
// lookup) — a real permit-derived range instead of "Insufficient data",
// just without the materials/labor split. `materials_included: false` is
// what callers (Swift `PricingService`) key off of to label this
// explicitly as permit-only rather than the fuller permits+materials range.
export interface PermitOnlyRange {
  materials_included: false;
  all_in_low: number;
  all_in_high: number;
  data_points: number;
  confidence: "high" | "med" | "low";
  source: string;
}

export interface InsufficientDataResult {
  error: string;
  fallback: string;
}

// --- job_type -> SF permit description keywords -----------------------

export const JOB_TYPE_KEYWORDS: Record<string, string[]> = {
  "bathroom.vanity": ["vanity", "bathroom sink"],
  "bathroom.full": ["bathroom remodel", "bathroom renovation"],
  "kitchen.remodel": ["kitchen remodel", "kitchen renovation"],
  "plumbing.water_heater": ["water heater"],
  "electrical.panel": ["panel upgrade", "electrical panel", "breaker panel"],
  "hvac.furnace": ["furnace"],
  "windows_doors.window": ["window replacement", "window install"],
  "carpentry.deck": ["deck"],
};

// --- keyword rules for normalizing a free-text permit description -----
//
// Covers one flagship job per home Category that (a) actually gets an SF
// building permit — cosmetic work like painting, flooring refinishing, and
// landscaping generally doesn't, so those categories have no permit trail
// for this formula to use at all and are intentionally NOT covered here —
// and (b) has an enumerable materials list. See home-pricing-engine memory
// for the full per-category reasoning.
//
// SF permits are often filed for a whole bundle of work at once (e.g. "add
// ADU, kitchen remodel, water heater replacement, panel upgrade, structural
// work — $95,000"). A naive substring match on "water heater" pulls that
// $95,000 permit into what should be a standalone-water-heater-job dataset
// and blows the range out to something implausible. `excludeIfContains`
// keeps a standalone-trade job_type from matching a permit that's actually
// describing bundled bigger-scope work — verified 2026-07-03 against real
// SF data, where this was producing ranges like $9,630-$96,000 for a water
// heater before this fix. Not applied to the remodel job_types themselves
// (bathroom.full, kitchen.remodel), since bundled scope IS what they mean.
const BIG_SCOPE_SIGNALS = [
  "remodel", "renovation", "addition", "adu", "accessory dwelling",
  "new construction", "full gut", "rebuild", "reconstruct", "structural",
  // Code-enforcement / legalization permits (retroactively permitting
  // unpermitted work found via a Notice of Violation) also bundle a much
  // wider inspection-driven scope than the single trade they mention —
  // found 2026-07-03 in windows_doors.window real data ("legalize
  // unwarranted structure @ 2/f, reconfigure rear staircase..." at $80,000).
  "legaliz", "unwarranted", "notice of violation", "comply with nov", "structure",
];

const NORMALIZE_RULES: Array<{ job_type: string; keywords: string[]; excludeIfContains?: string[] }> = [
  { job_type: "bathroom.vanity", keywords: ["vanity"] },
  { job_type: "bathroom.full", keywords: ["bathroom remodel", "bathroom renovation", "full bath"] },
  { job_type: "kitchen.remodel", keywords: ["kitchen remodel", "kitchen renovation"] },
  { job_type: "plumbing.water_heater", keywords: ["water heater"], excludeIfContains: BIG_SCOPE_SIGNALS },
  { job_type: "electrical.panel", keywords: ["panel upgrade", "electrical panel", "breaker panel"], excludeIfContains: BIG_SCOPE_SIGNALS },
  { job_type: "hvac.furnace", keywords: ["furnace"], excludeIfContains: BIG_SCOPE_SIGNALS },
  { job_type: "windows_doors.window", keywords: ["window replacement", "replace window", "new window"], excludeIfContains: BIG_SCOPE_SIGNALS },
  { job_type: "carpentry.deck", keywords: ["deck"], excludeIfContains: BIG_SCOPE_SIGNALS },
];

// Materials required to price a given job_type, matched against
// Material.name by substring. All categories must have at least one match
// for calculateMaterialFloor to return a number.
const REQUIRED_MATERIAL_CATEGORIES: Record<string, string[]> = {
  "bathroom.vanity": ["vanity", "top", "faucet", "mirror"],
  "bathroom.full": ["tub", "toilet", "vanity", "tile"],
  "plumbing.water_heater": ["water heater"],
  "electrical.panel": ["panel"],
  "hvac.furnace": ["furnace"],
  "windows_doors.window": ["window"],
  "carpentry.deck": ["decking"],
};

// Retail search queries per required category, parameterized by width so
// "36in vanity" and "60in vanity" price differently. Category order here
// must match REQUIRED_MATERIAL_CATEGORIES so results line up.
//
// `bathroom.full` has no single "width" the way a vanity does — width_in is
// reused loosely as an overall bathroom-size proxy (also what
// calculatePermitRange's +/-6in window matches permits on) rather than a
// literal fixture dimension. Revisit once JobScope generalizes to a
// job-type-specific quantity/unit instead of width_in for every job.
//
// `plumbing.water_heater` / `electrical.panel` / `hvac.furnace` /
// `carpentry.deck` aren't sized by width at all (capacity, amperage, or
// area instead) — width_in is accepted but unused for these; permit
// descriptions for this kind of work essentially never parse a size out of
// `normalizeScope` either, so calculatePermitRange's +/-6in window is
// effectively a no-op rather than wrongly filtering on an irrelevant
// dimension. `windows_doors.window` is the one new job_type where width_in
// is a literal, meaningful dimension again, same as vanity.
const MATERIAL_QUERIES: Record<string, (widthIn: number) => Record<string, string>> = {
  "bathroom.vanity": (widthIn) => ({
    vanity: `bathroom vanity cabinet ${widthIn} in`,
    top: `${widthIn} inch vanity top`,
    faucet: "bathroom sink faucet",
    mirror: `${widthIn} inch bathroom mirror`,
  }),
  "bathroom.full": (widthIn) => ({
    tub: "bathtub",
    toilet: "toilet",
    vanity: `${widthIn} inch bathroom vanity cabinet`,
    tile: "bathroom floor tile",
  }),
  "plumbing.water_heater": () => ({
    "water heater": "40 gallon gas water heater",
  }),
  "electrical.panel": () => ({
    panel: "200 amp breaker panel",
  }),
  "hvac.furnace": () => ({
    furnace: "gas furnace",
  }),
  "windows_doors.window": (widthIn) => ({
    window: `${widthIn} inch vinyl replacement window`,
  }),
  "carpentry.deck": () => ({
    decking: "pressure treated decking board",
  }),
};

// --- fetchMaterialFloorRaw -------------------------------------------------
// Sources real retail prices from SerpApi's Home Depot engine — one search
// per required category — instead of requiring the client to already have
// a materials list. No caching here; the caller (index.ts) wraps this with
// a Postgres cache, same pattern as fetchSFPermitsRaw / search_cache.

const SERPAPI_URL = "https://serpapi.com/search.json";

interface HomeDepotProduct {
  product_id?: string;
  model_number?: string;
  title?: string;
  price?: number;
}

// SerpApi's Home Depot engine ignores `delivery_zip` for store selection —
// verified live 2026-07-03, it only filters delivery-eligible items and
// always falls back to store 2414 (Bangor, ME) if `store_id` isn't given
// (see https://github.com/serpapi/public-roadmap/issues/268). There's no
// zip-code param that resolves a nearest store server-side, so we resolve
// it ourselves from SerpApi's published store list
// (https://serpapi.com/home-depot-stores-us.json). Only Bay Area stores are
// listed here since PricingService.swift currently gates on San Francisco
// locality — extend this table if coverage expands beyond the Bay Area.
const BAY_AREA_STORES: { storeId: string; zip: string }[] = [
  { storeId: "639", zip: "94014" }, // Colma — closest to SF proper
  { storeId: "6655", zip: "94014" }, // Colma (2nd location)
  { storeId: "1092", zip: "94015" }, // Daly City
  { storeId: "628", zip: "94070" }, // San Carlos
  { storeId: "632", zip: "94404" }, // San Mateo
  { storeId: "627", zip: "94608" }, // Emeryville
  { storeId: "1007", zip: "94601" }, // Oakland
  { storeId: "657", zip: "94901" }, // San Rafael
];
const DEFAULT_STORE_ID = "639"; // Colma — used when zip is missing/unrecognized

/** Nearest Bay Area store by numeric zip distance — not geographically
 *  precise, but zip codes cluster regionally so it's a reasonable proxy,
 *  and far better than SerpApi's random-store default. */
export function nearestStoreId(zip: string | undefined): string {
  const target = Number(zip);
  if (!zip || Number.isNaN(target)) return DEFAULT_STORE_ID;

  let best = BAY_AREA_STORES[0];
  let bestDist = Math.abs(Number(best.zip) - target);
  for (const store of BAY_AREA_STORES.slice(1)) {
    const dist = Math.abs(Number(store.zip) - target);
    if (dist < bestDist) {
      best = store;
      bestDist = dist;
    }
  }
  return best.storeId;
}

async function fetchHomeDepotPrice(query: string, storeId: string, apiKey: string): Promise<Material | null> {
  const url = `${SERPAPI_URL}?${new URLSearchParams({
    engine: "home_depot",
    q: query,
    country: "us",
    ps: "1",
    store_id: storeId,
    api_key: apiKey,
  })}`;

  const res = await fetch(url);
  if (!res.ok) throw new Error(`SerpApi Home Depot search returned ${res.status}`);
  const body = (await res.json()) as { products?: HomeDepotProduct[] };
  const product = body.products?.[0];
  if (!product || typeof product.price !== "number" || !product.title) return null;

  return {
    sku: product.model_number ?? product.product_id ?? query,
    name: product.title,
    price: product.price,
  };
}

/** Returns one Material per required category for job_type, or null if the
 *  job_type isn't covered, the API key is missing, or any category has no
 *  priced result — calculateMaterialFloor treats a shorter list as missing. */
export async function fetchMaterialFloorRaw(
  scope: JobScope,
  apiKey: string,
): Promise<Material[] | null> {
  const buildQueries = MATERIAL_QUERIES[scope.job_type];
  if (!buildQueries || !apiKey) return null;

  const storeId = nearestStoreId(scope.zip);
  const queries = buildQueries(scope.width_in);
  const materials = await Promise.all(
    Object.values(queries).map((q) => fetchHomeDepotPrice(q, storeId, apiKey)),
  );

  if (materials.some((m) => m === null)) return null;
  return materials as Material[];
}

// --- fetchSFPermitsRaw ---------------------------------------------------
// No caching here — the caller (index.ts) wraps this with a Postgres cache,
// same pattern as the `search` function's search_cache table.

export function buildPermitQueryUrl(jobKeywords: string[], months: number): string {
  const cutoff = new Date();
  cutoff.setMonth(cutoff.getMonth() - months);
  const cutoffIso = cutoff.toISOString().slice(0, 10);

  // The dataset's SoQL compiler rejects ILIKE outright ("query.compiler.malformed")
  // — verified directly against the live endpoint. lower(description) like
  // '<lowercase pattern>' is the case-insensitive equivalent it actually accepts.
  const keywordClause = jobKeywords
    .map((kw) => `lower(description) like '%${kw.toLowerCase().replace(/'/g, "''")}%'`)
    .join(" OR ");
  const where = `(${keywordClause}) AND filed_date > '${cutoffIso}'`;

  return `${SF_PERMITS_ENDPOINT}?$where=${encodeURIComponent(where)}&$limit=5000`;
}

export async function fetchSFPermitsRaw(
  jobKeywords: string[],
  months: number,
  appToken?: string,
): Promise<Permit[]> {
  const url = buildPermitQueryUrl(jobKeywords, months);
  const headers: Record<string, string> = {};
  if (appToken) headers["X-App-Token"] = appToken;

  const res = await fetch(url, { headers });
  if (!res.ok) {
    throw new Error(`SF permits API returned ${res.status}`);
  }
  // deno-lint-ignore no-explicit-any
  const rows = (await res.json()) as any[];

  return rows
    .map((row) => ({
      contractor: row.contractor_name ?? null,
      description: row.description ?? "",
      estimated_cost: Number(row.estimated_cost ?? 0),
      filed_date: row.filed_date ?? "",
      completed_date: row.completed_date ?? null,
      status: row.status ?? "",
    }))
    .filter((p) => p.status.toLowerCase() !== "withdrawn");
}

// --- normalizeScope ---------------------------------------------------

export function normalizeScope(description: string): { job_type: string; size: number | null } | null {
  const text = description.toLowerCase();

  const sizeMatch = text.match(/(\d+)\s*(?:in\b|inch|")/);
  const size = sizeMatch ? Number(sizeMatch[1]) : null;

  for (const rule of NORMALIZE_RULES) {
    if (!rule.keywords.some((kw) => text.includes(kw))) continue;
    // Bundled into bigger-scope work — not a standalone match for this
    // job_type. Keep checking other rules (it may still match a remodel
    // job_type instead) rather than returning null outright.
    if (rule.excludeIfContains?.some((kw) => text.includes(kw))) continue;
    return { job_type: rule.job_type, size };
  }

  return null;
}

function normalizePermits(permits: Permit[]): NormalizedPermit[] {
  return permits
    .map((p) => {
      const normalized = normalizeScope(p.description);
      if (!normalized) return null;
      return { ...p, job_type: normalized.job_type, size: normalized.size };
    })
    .filter((p): p is NormalizedPermit => p !== null);
}

// --- calculatePermitRange ---------------------------------------------

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 1) return sorted[0];
  const idx = (p / 100) * (sorted.length - 1);
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  const frac = idx - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

// Statistical safety net on top of `excludeIfContains`: even a permit whose
// description looks standalone can carry a wildly bundled/miskeyed
// valuation. Standard 1.5×IQR outlier trim before computing percentiles —
// no per-category hardcoded price assumptions, just removing points that
// are statistical outliers relative to this specific matched set. Needs at
// least 4 points to compute a meaningful IQR; smaller sets pass through
// untrimmed (the >=10 minimum is enforced on the pre-trim matched count).
function trimOutliers(sortedCosts: number[]): number[] {
  if (sortedCosts.length < 4) return sortedCosts;
  const q1 = percentile(sortedCosts, 25);
  const q3 = percentile(sortedCosts, 75);
  const iqr = q3 - q1;
  const lo = q1 - 1.5 * iqr;
  const hi = q3 + 1.5 * iqr;
  return sortedCosts.filter((c) => c >= lo && c <= hi);
}

// SF permit "revisions" (amendments to an already-filed permit — description
// starts "revision to <permit#>" or "rev <permit#>") carry a placeholder
// valuation, often exactly $1, since the real cost was already declared on
// the original permit. Verified 2026-07-03 against live data: up to 12% of
// matched permits for some job types (carpentry.deck) were these
// placeholders, dragging the low end of the range toward $1.
// Not anchored to the start — "unit a: revision to existing permit#..." is
// a real example that an anchored pattern missed (found 2026-07-03).
const REVISION_PATTERN = /(revision to|\brev\.?\s)/i;
// A real construction job is never priced at $1-$99 — that range is always
// a placeholder/artifact, not an actual cost. Belt-and-suspenders alongside
// the revision-pattern exclude, since not every placeholder-cost permit
// necessarily matches that description pattern.
const MIN_PLAUSIBLE_COST = 100;

export function calculatePermitRange(permits: Permit[], scope: JobScope): PermitRange | null {
  const normalized = normalizePermits(permits);

  const matched = normalized.filter((p) => {
    if (REVISION_PATTERN.test(p.description)) return false;
    if (p.job_type !== scope.job_type) return false;
    if (p.size === null) return true;
    return Math.abs(p.size - scope.width_in) <= 6;
  });

  if (matched.length < 10) return null;

  // Prefer a tighter match on scope.features (e.g. "40 gallon", "tankless" —
  // typically extracted from a photo capture, see PricingService.swift's
  // detectFeatureTokens) when there's still enough data to support it. Real
  // permit-description substring matching, not a guess — just more specific
  // to this request than job_type + size alone. Falls back to the broader
  // `matched` set when tightening would leave too little to be valid.
  const features = (scope.features ?? []).map((f) => f.toLowerCase()).filter((f) => f.length > 0);
  let pool = matched;
  if (features.length > 0) {
    const tighter = matched.filter((p) => features.some((f) => p.description.toLowerCase().includes(f)));
    if (tighter.length >= 10) pool = tighter;
  }

  const rawCosts = pool.map((p) => p.estimated_cost).filter((c) => c >= MIN_PLAUSIBLE_COST).sort((a, b) => a - b);
  if (rawCosts.length < 10) return null;

  const costs = trimOutliers(rawCosts);

  return {
    p25: percentile(costs, 25),
    p50: percentile(costs, 50),
    p75: percentile(costs, 75),
    count: costs.length,
  };
}

// --- calculateMaterialFloor --------------------------------------------

export function calculateMaterialFloor(materials: Material[], scope: JobScope): number | null {
  const categories = REQUIRED_MATERIAL_CATEGORIES[scope.job_type];
  if (!categories) return null;

  let total = 0;
  for (const category of categories) {
    const match = materials.find((m) => m.name.toLowerCase().includes(category));
    if (!match) return null;
    total += match.price;
  }
  return total;
}

// --- buildLocalRange ----------------------------------------------------
// Pure combine step — permit range + material floor -> the displayable
// range. Split out from getLocalRange (the Node version) so index.ts can
// own the fetch + Postgres cache orchestration.

export function buildLocalRange(permitRange: PermitRange, materialFloor: number): LocalRange {
  // valuations are lowballed
  const p25 = permitRange.p25 * PERMIT_VALUATION_BUFFER;
  const p75 = permitRange.p75 * PERMIT_VALUATION_BUFFER;

  const material_low = materialFloor * 0.9;
  const material_high = materialFloor * 1.3;

  const labor_low = Math.max(p25 - materialFloor, SF_LABOR_FLOOR);
  const labor_high = p75 - materialFloor;

  return {
    materials_included: true,
    material_low,
    material_high,
    labor_low,
    labor_high,
    all_in_low: material_low + labor_low,
    all_in_high: material_high + labor_high,
    data_points: permitRange.count,
    confidence: permitRange.count > 30 ? "high" : permitRange.count > 10 ? "med" : "low",
    source: "SF DBI permits + retail pricing",
  };
}

// --- buildPermitOnlyRange -------------------------------------------------
// Fallback when permit data is good but materials pricing isn't available
// (no SERPAPI_KEY yet, or a category with no material lookup configured).
// A real permit-derived range beats "Insufficient data" — it just can't be
// split into materials/labor without a material floor to subtract.

export function buildPermitOnlyRange(permitRange: PermitRange): PermitOnlyRange {
  // valuations are lowballed
  return {
    materials_included: false,
    all_in_low: permitRange.p25 * PERMIT_VALUATION_BUFFER,
    all_in_high: permitRange.p75 * PERMIT_VALUATION_BUFFER,
    data_points: permitRange.count,
    confidence: permitRange.count > 30 ? "high" : permitRange.count > 10 ? "med" : "low",
    source: "SF DBI permit data only (materials pricing unavailable)",
  };
}

// --- formatDisplayText -------------------------------------------------

function money(n: number): string {
  return `$${Math.round(n).toLocaleString("en-US")}`;
}

export function formatDisplayText(
  range: LocalRange | PermitOnlyRange | InsufficientDataResult,
): string {
  if ("error" in range) {
    return `${range.error}. ${range.fallback}.`;
  }

  if (!range.materials_included) {
    const lines = [
      `Typical cost in San Francisco: ${money(range.all_in_low)}-${money(range.all_in_high)}`,
      `Based on ${range.data_points} SF permit${range.data_points === 1 ? "" : "s"} — ` +
      `permit data only, materials pricing wasn't available for this breakdown.`,
    ];
    if (range.confidence === "low") {
      lines.push("Ranges vary widely. Get firm bids on your scope.");
    }
    return lines.join("\n");
  }

  const lines = [
    `Typical all-in cost in San Francisco: ${money(range.all_in_low)}-${money(range.all_in_high)}`,
    `Based on ${range.data_points} city permits + material costs, last 6 months.`,
    `Materials: ~${money(range.material_low)}-${money(range.material_high)}. Labor + permits: ~${money(
      range.labor_low,
    )}-${money(range.labor_high)}.`,
  ];

  if (range.confidence === "low") {
    lines.push("Ranges vary widely. Get firm bids on your scope.");
  }

  return lines.join("\n");
}

// --- Multi-category nationwide estimate (EstimationPro/EPCI) ---------------
//
// Adopted this session as the primary, nationwide data source across all 10
// app categories — the permit engine above only ever covered 7 narrow
// job_types in San Francisco, and was producing implausible ranges even for
// those (e.g. $8,754-$48,197 for a water heater, verified live 2026-07-03).
// EPCI = EstimationPro's free, self-serve construction cost API
// (estimationpro.ai/api/v1), BLS wage- and PPI-backed, not a guess.
//
// NOTE: EstimationPro's own API responses carry
// `"license":"Free for non-commercial use with attribution"` and no
// commercial price is published yet — a licensing email is in flight.
// Until that's resolved, index.ts gates real usage behind the
// `EPCI_ENABLED` secret (default unset/false); everything below works
// regardless, so it's ready the moment that flips.

const EPCI_BASE_URL = "https://estimationpro.ai/api/v1";

export interface EPCIItem {
  id: string;
  description: string;
  unit: string;
  low: number;
  typical: number;
  high: number;
  regionallyAdjusted: boolean;
}

export interface JobTypeEntry {
  job_type: string;
  category: string;        // matches the app's Category.rawValue
  keywords: string[];       // matched against description + photo attributes, lowercased; empty = category-general fallback entry
  trade: string;            // EPCI `trade` query param
  itemId: string;           // EPCI item id to price against
  unit: string;             // expected unit of measure, informational
  defaultQuantity: number;  // used when no explicit quantity is detected — lowers confidence
}

// One flagship job per category that EPCI prices well, plus a per-category
// ".general" fallback (CATEGORY_GENERAL below) so every mapped category
// always returns *something* even when the description is too generic to
// pin down a specific job. Item ids, units, and price shape verified live
// against estimationpro.ai/api/v1/costs this session — not guessed.
export const JOB_TYPE_TAXONOMY: JobTypeEntry[] = [
  // Plumbing
  { job_type: "plumbing.water_heater", category: "Plumbing", keywords: ["water heater"], trade: "plumbing", itemId: "water-heater-install", unit: "project", defaultQuantity: 1 },
  { job_type: "plumbing.tankless_water_heater", category: "Plumbing", keywords: ["tankless"], trade: "plumbing", itemId: "tankless-water-heater-install", unit: "project", defaultQuantity: 1 },
  { job_type: "plumbing.fixture", category: "Plumbing", keywords: ["faucet", "toilet", "sink", "fixture"], trade: "plumbing", itemId: "fixture-install", unit: "each", defaultQuantity: 1 },
  { job_type: "plumbing.pipe_repair", category: "Plumbing", keywords: ["leak", "clog", "drain"], trade: "plumbing", itemId: "pipe-repair", unit: "project", defaultQuantity: 1 },
  { job_type: "plumbing.repipe", category: "Plumbing", keywords: ["repipe", "repiping"], trade: "plumbing", itemId: "whole-house-repipe-pex", unit: "sq ft", defaultQuantity: 1500 },
  { job_type: "plumbing.sewer_line", category: "Plumbing", keywords: ["sewer"], trade: "plumbing", itemId: "sewer-line-replacement", unit: "linear foot", defaultQuantity: 50 },

  // Electrical
  { job_type: "electrical.panel", category: "Electrical", keywords: ["panel upgrade", "electrical panel", "breaker panel", "200 amp"], trade: "electrical", itemId: "panel-upgrade-200amp", unit: "project", defaultQuantity: 1 },
  { job_type: "electrical.outlet", category: "Electrical", keywords: ["outlet", "socket"], trade: "electrical", itemId: "outlet-installation", unit: "each", defaultQuantity: 1 },
  { job_type: "electrical.ceiling_fan", category: "Electrical", keywords: ["ceiling fan"], trade: "electrical", itemId: "ceiling-fan-install", unit: "each", defaultQuantity: 1 },
  { job_type: "electrical.ev_charger", category: "Electrical", keywords: ["ev charger", "car charger"], trade: "electrical", itemId: "ev-charger-level2", unit: "each", defaultQuantity: 1 },
  { job_type: "electrical.rewire", category: "Electrical", keywords: ["rewire", "rewiring"], trade: "electrical", itemId: "whole-house-rewire", unit: "sq ft", defaultQuantity: 1500 },
  { job_type: "electrical.lighting", category: "Electrical", keywords: ["light", "lighting"], trade: "electrical", itemId: "light-fixture-install", unit: "each", defaultQuantity: 1 },

  // HVAC
  { job_type: "hvac.furnace", category: "HVAC", keywords: ["furnace"], trade: "hvac", itemId: "gas-furnace-installed", unit: "project", defaultQuantity: 1 },
  { job_type: "hvac.ac", category: "HVAC", keywords: ["central air", "air condition", "a/c"], trade: "hvac", itemId: "central-ac-installed", unit: "project", defaultQuantity: 1 },
  { job_type: "hvac.heat_pump", category: "HVAC", keywords: ["heat pump"], trade: "hvac", itemId: "heat-pump-installed", unit: "project", defaultQuantity: 1 },
  { job_type: "hvac.mini_split", category: "HVAC", keywords: ["mini split", "ductless"], trade: "hvac", itemId: "mini-split-per-zone", unit: "each", defaultQuantity: 1 },
  { job_type: "hvac.thermostat", category: "HVAC", keywords: ["thermostat"], trade: "hvac", itemId: "thermostat-installation-smart", unit: "each", defaultQuantity: 1 },
  { job_type: "hvac.repair", category: "HVAC", keywords: ["repair", "tune-up", "tune up", "service"], trade: "hvac", itemId: "furnace-repair", unit: "project", defaultQuantity: 1 },

  // Painting
  { job_type: "painting.interior", category: "Painting", keywords: ["interior", "room", "wall color", "repaint"], trade: "paint", itemId: "paint-interior-labor", unit: "sq ft", defaultQuantity: 250 },
  { job_type: "painting.exterior", category: "Painting", keywords: ["exterior"], trade: "paint", itemId: "paint-exterior-labor", unit: "sq ft", defaultQuantity: 1500 },
  { job_type: "painting.cabinet", category: "Painting", keywords: ["cabinet"], trade: "paint", itemId: "cabinet-painting-spray", unit: "linear foot", defaultQuantity: 20 },

  // Carpentry
  { job_type: "carpentry.deck", category: "Carpentry", keywords: ["deck"], trade: "deck", itemId: "pressure-treated-installed", unit: "sq ft", defaultQuantity: 300 },
  { job_type: "carpentry.cabinet", category: "Carpentry", keywords: ["cabinet", "cabinetry"], trade: "cabinetry", itemId: "stock-cabinets-installed", unit: "linear foot", defaultQuantity: 15 },
  { job_type: "carpentry.framing", category: "Carpentry", keywords: ["framing", "beam", "header", "load bearing", "load-bearing"], trade: "framing", itemId: "wall-framing", unit: "linear foot", defaultQuantity: 20 },

  // Roofing
  { job_type: "roofing.replacement", category: "Roofing", keywords: ["replace", "replacement", "new roof", "reroof"], trade: "roofing", itemId: "roof-replacement-total", unit: "project", defaultQuantity: 1 },
  { job_type: "roofing.repair", category: "Roofing", keywords: ["repair", "patch", "leak"], trade: "roofing", itemId: "roof-repair-patch", unit: "sq ft", defaultQuantity: 50 },
  { job_type: "roofing.gutter", category: "Roofing", keywords: ["gutter"], trade: "roofing", itemId: "gutter-install-aluminum", unit: "linear foot", defaultQuantity: 150 },

  // Flooring
  { job_type: "flooring.hardwood", category: "Flooring", keywords: ["hardwood"], trade: "flooring", itemId: "hardwood-installed", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "flooring.laminate", category: "Flooring", keywords: ["laminate"], trade: "flooring", itemId: "laminate-installed", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "flooring.lvp", category: "Flooring", keywords: ["vinyl plank", "lvp"], trade: "flooring", itemId: "lvp-installed", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "flooring.carpet", category: "Flooring", keywords: ["carpet", "rug"], trade: "flooring", itemId: "carpet-installed", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "flooring.tile", category: "Flooring", keywords: ["tile"], trade: "flooring", itemId: "tile-installed", unit: "sq ft", defaultQuantity: 150 },
  { job_type: "flooring.refinish", category: "Flooring", keywords: ["refinish", "refinishing", "sand"], trade: "flooring", itemId: "hardwood-refinishing", unit: "sq ft", defaultQuantity: 200 },

  // Windows & Doors
  { job_type: "windows_doors.window", category: "Windows & Doors", keywords: ["window replacement", "replace window", "new window", "window"], trade: "windows", itemId: "vinyl-window-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "windows_doors.exterior_door", category: "Windows & Doors", keywords: ["exterior door", "entry door", "front door"], trade: "doors", itemId: "exterior-door-steel", unit: "each", defaultQuantity: 1 },
  { job_type: "windows_doors.interior_door", category: "Windows & Doors", keywords: ["interior door", "closet door", "bedroom door"], trade: "doors", itemId: "interior-door-hollow-core", unit: "each", defaultQuantity: 1 },
  { job_type: "windows_doors.garage_door", category: "Windows & Doors", keywords: ["garage door"], trade: "doors", itemId: "garage-door-single", unit: "each", defaultQuantity: 1 },

  // Landscaping
  { job_type: "landscaping.lawn", category: "Landscaping", keywords: ["lawn", "sod", "grass"], trade: "landscaping", itemId: "sod-installation", unit: "sq ft", defaultQuantity: 1000 },
  { job_type: "landscaping.tree", category: "Landscaping", keywords: ["tree"], trade: "landscaping", itemId: "tree-removal", unit: "each", defaultQuantity: 1 },
  { job_type: "landscaping.irrigation", category: "Landscaping", keywords: ["irrigation", "sprinkler"], trade: "landscaping", itemId: "irrigation-system-per-zone", unit: "each", defaultQuantity: 1 },
  { job_type: "landscaping.patio", category: "Landscaping", keywords: ["patio", "hardscape", "paver"], trade: "landscaping", itemId: "paver-patio-installation", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "landscaping.mulch", category: "Landscaping", keywords: ["mulch"], trade: "landscaping", itemId: "mulch-installation", unit: "cubic yard", defaultQuantity: 5 },
];

// Per-category fallback used when nothing in JOB_TYPE_TAXONOMY matches the
// description/photo attributes — keeps the promise that every *mapped*
// category always returns a real number, not just the ones a user happens
// to describe precisely. `null` = intentionally unmapped: Mold & Pest
// Control has no EPCI trade at all (same gap SF permits had), so it stays
// on the "coming soon" fallback by explicit decision this session.
export const CATEGORY_GENERAL: Record<string, JobTypeEntry | null> = {
  "Plumbing": { job_type: "plumbing.general", category: "Plumbing", keywords: [], trade: "plumbing", itemId: "plumber-hourly", unit: "hour", defaultQuantity: 2 },
  "Electrical": { job_type: "electrical.general", category: "Electrical", keywords: [], trade: "electrical", itemId: "electrician-hourly", unit: "hour", defaultQuantity: 2 },
  "HVAC": { job_type: "hvac.general", category: "HVAC", keywords: [], trade: "hvac", itemId: "hvac-labor-rate", unit: "hour", defaultQuantity: 2 },
  "Painting": { job_type: "painting.general", category: "Painting", keywords: [], trade: "paint", itemId: "paint-interior-labor", unit: "sq ft", defaultQuantity: 250 },
  "Carpentry": { job_type: "carpentry.general", category: "Carpentry", keywords: [], trade: "framing", itemId: "framing-labor-rate", unit: "sq ft", defaultQuantity: 200 },
  "Roofing": { job_type: "roofing.general", category: "Roofing", keywords: [], trade: "roofing", itemId: "roof-repair-patch", unit: "sq ft", defaultQuantity: 50 },
  "Flooring": { job_type: "flooring.general", category: "Flooring", keywords: [], trade: "flooring", itemId: "laminate-installed", unit: "sq ft", defaultQuantity: 200 },
  "Windows & Doors": { job_type: "windows_doors.general", category: "Windows & Doors", keywords: [], trade: "windows", itemId: "vinyl-window-replacement", unit: "each", defaultQuantity: 1 },
  "Landscaping": { job_type: "landscaping.general", category: "Landscaping", keywords: [], trade: "landscaping", itemId: "mulch-installation", unit: "cubic yard", defaultQuantity: 3 },
  "Mold & Pest Control": null,
};

// The 5 job_types that overlap the original SF-permit engine's coverage
// (see JOB_TYPE_KEYWORDS / NORMALIZE_RULES above) — permits are consulted as
// a cross-check for these only, when the request resolves to an SF zip
// (941xx), and only ever boost confidence — they never override the EPCI
// number. Two of the original 7 permit job_types (bathroom.vanity,
// bathroom.full) have no equivalent in the app's 10-category taxonomy —
// "Bathroom" isn't an app Category — so they no longer get a cross-check.
export const LEGACY_PERMIT_JOB_TYPES = new Set([
  "plumbing.water_heater",
  "electrical.panel",
  "hvac.furnace",
  "windows_doors.window",
  "carpentry.deck",
]);

// Category-name stems for inferring the category from free text when the
// client has none (typed search, no category chip — the client can't recover
// a category from a multi-word phrase and sends it empty). Substring-matched
// like taxonomy keywords ("floor" hits "flooring" and "floors"). HVAC
// deliberately has no "heat"/"air" stem — "water heater" must not route to
// HVAC; its job keywords ("furnace", "heat pump") carry that category.
const CATEGORY_STEMS: Record<string, string[]> = {
  "Plumbing": ["plumb"],
  "Electrical": ["electric"],
  "HVAC": ["hvac"],
  "Painting": ["paint"],
  "Carpentry": ["carpent"],
  "Roofing": ["roof"],
  "Flooring": ["floor"],
  "Windows & Doors": ["window", "door"],
  "Landscaping": ["landscap", "yard", "garden"],
  "Mold & Pest Control": ["pest", "mold"],
};

// Keywords that disambiguate jobs only *within* a category ("repair" means
// hvac.repair under HVAC and roofing.repair under Roofing) and so must not
// classify on their own when no category is known — "replaced hardwood
// floor" must not hit roofing.replacement via "replace". "light" is here
// because "skylight" contains it.
const WITHIN_CATEGORY_ONLY = new Set([
  "repair", "replace", "replacement", "service", "tune-up", "tune up",
  "patch", "leak", "fixture", "interior", "exterior", "room", "light",
  "lighting", "sand", "cabinet",
]);

export function classifyJobType(
  category: string,
  description: string,
  photoAttributes: string[] = [],
): JobTypeEntry | null {
  const text = [description, ...photoAttributes].join(", ").toLowerCase();
  if (category) {
    const candidates = JOB_TYPE_TAXONOMY.filter((entry) => entry.category === category);
    const specific = candidates.find((entry) => entry.keywords.some((kw) => text.includes(kw)));
    if (specific) return specific;
    return CATEGORY_GENERAL[category] ?? null;
  }

  // No category from the client — infer it from the description. A single
  // category-stem hit routes through the normal per-category path above, so
  // "fix my roof" still lands on a real number via the category-general
  // entry even when no job keyword matches.
  const stemmed = Object.keys(CATEGORY_STEMS)
    .filter((cat) => CATEGORY_STEMS[cat].some((s) => text.includes(s)));
  if (stemmed.length === 1) return classifyJobType(stemmed[0], description, photoAttributes);

  // No stem (or several) — scan job keywords, longest match wins as the
  // most specific ("water heater" beats "heater"-less generics). With no
  // category signal at all, within-category-only keywords are skipped;
  // when stems narrowed the pool they're safe to use again.
  const pool = stemmed.length > 0
    ? JOB_TYPE_TAXONOMY.filter((entry) => stemmed.includes(entry.category))
    : JOB_TYPE_TAXONOMY;
  let best: JobTypeEntry | null = null;
  let bestLen = 0;
  for (const entry of pool) {
    for (const kw of entry.keywords) {
      if (stemmed.length === 0 && WITHIN_CATEGORY_ONLY.has(kw)) continue;
      if (kw.length > bestLen && text.includes(kw)) {
        best = entry;
        bestLen = kw.length;
      }
    }
  }
  return best;
}

// Explicit quantity beats the taxonomy default — the default is a real
// number too, just a rougher one, reflected in the caller's confidence level
// (see index.ts).
export function resolveQuantity(
  entry: JobTypeEntry,
  description: string,
): { quantity: number; isDefaulted: boolean } {
  const explicit = description.match(
    /(\d+(?:\.\d+)?)\s*(?:sq\s*\.?\s*ft|square\s*feet|sf|linear\s*f(?:oo|ee)?t|lf|ft)\b/i,
  );
  if (explicit) {
    const value = Number(explicit[1]);
    if (value > 0) return { quantity: value, isDefaulted: false };
  }
  return { quantity: entry.defaultQuantity, isDefaulted: true };
}

interface EPCICostsResponse {
  data: {
    trade: string;
    location: string;
    multiplier: number;
    items: EPCIItem[];
  };
}

/** No caching here — the caller (index.ts) wraps this with a Postgres cache,
 *  same pattern as fetchSFPermitsRaw / fetchMaterialFloorRaw. */
export async function fetchEPCIRaw(trade: string, zip: string | undefined): Promise<EPCIItem[]> {
  const params = new URLSearchParams({ trade });
  if (zip) params.set("zip", zip);
  const res = await fetch(`${EPCI_BASE_URL}/costs?${params}`);
  if (!res.ok) throw new Error(`EstimationPro API returned ${res.status}`);
  const body = (await res.json()) as EPCICostsResponse;
  return body.data.items;
}

export interface EPCIComputedRange {
  all_in_low: number;
  all_in_high: number;
}

export function calculateEPCIRange(
  items: EPCIItem[],
  entry: JobTypeEntry,
  quantity: number,
): EPCIComputedRange | null {
  const item = items.find((i) => i.id === entry.itemId);
  if (!item) return null;
  return { all_in_low: item.low * quantity, all_in_high: item.high * quantity };
}

export function rangesOverlap(aLow: number, aHigh: number, bLow: number, bHigh: number): boolean {
  return aLow <= bHigh && bLow <= aHigh;
}
