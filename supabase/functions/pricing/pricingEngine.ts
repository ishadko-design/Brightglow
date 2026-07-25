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
  /** Job cost that does NOT scale with quantity — mobilization, demo and
   *  disposal, protection and masking, layout, edge/trim detail, cleanup, the
   *  half-day nobody bills below. Added once per job; the per-unit rates above
   *  carry only the marginal cost of one more unit.
   *
   *  Without this the engine was linear to zero: 40 sq ft of bathroom tile
   *  computed to $585 against a real $1,800-6,300, because a small job pays
   *  almost the same setup as a large one over a fifth of the area (reported
   *  2026-07-22). Absent on items already priced as a whole project. */
  setupLow?: number;
  setupTypical?: number;
  setupHigh?: number;
}

export interface JobTypeEntry {
  job_type: string;
  category: string;        // matches the app's Category.rawValue
  keywords: string[];       // matched against description + photo attributes, lowercased; empty = category-general fallback entry
  trade: string;            // EPCI `trade` query param
  itemId: string;           // EPCI item id to price against
  unit: string;             // expected unit of measure, informational
  defaultQuantity: number;  // used when no explicit quantity is detected — lowers confidence
  /** Tiebreak ABOVE keyword length (default 0). Longest-match alone picks the
   *  generic entry whenever the specific job's distinguishing word is shorter
   *  than a generic keyword that also matches — "install a tankless water
   *  heater" matched "water heater" (12) over "tankless" (8) and priced a tank
   *  unit, 55% under the real job. Same failure hit "ductless mini split air
   *  conditioner" (→ central AC) and "metal roof replacement" (→ generic
   *  reroof). Set to 1 on the entry that must win when both match. */
  priority?: number;
  /** Words that disqualify this entry outright, however well its keywords
   *  match. For whole-system items where a maintenance verb means a completely
   *  different job: "solar panel repair" matched the install entry and quoted
   *  a full 20-panel array (~$25k) for what is a service call. Declining beats
   *  answering with another job's price. */
  notIfContains?: string[];
}

// One flagship job per category that EPCI prices well, plus a per-category
// ".general" fallback (CATEGORY_GENERAL below) so every mapped category
// always returns *something* even when the description is too generic to
// pin down a specific job. Item ids, units, and price shape verified live
// against estimationpro.ai/api/v1/costs this session — not guessed.
export const JOB_TYPE_TAXONOMY: JobTypeEntry[] = [
  // Plumbing
  // REPLACE entries carry vetoes for the symptoms that mean REPAIR. Without
  // them "my toilet keeps running" matched the generic fixture entry on the
  // word "toilet" and quoted a $433 swap for a $30 flapper (2026-07-22).
  { job_type: "plumbing.water_heater", category: "Plumbing", keywords: ["water heater"], trade: "plumbing", itemId: "water-heater-install", unit: "project", defaultQuantity: 1, notIfContains: ["repair", "no hot water", "not heating", "pilot light", "thermocouple", "not enough hot water", "runs out fast", "popping noise"] },
  // Plumbing REPAIRS. Symptom phrasings are the point: people describe what
  // their house is doing, not which part failed. These carry priority 1 so a
  // symptom always beats the bare noun ("faucet", "toilet") on the install
  // entries. The LLM classifier is primary for typed text and picks from this
  // same taxonomy, so the job_type existing at all is most of the fix.
  { job_type: "plumbing.toilet_repair", category: "Plumbing", keywords: ["toilet keeps running", "running toilet", "toilet running", "toilet wont stop", "toilet won't stop", "toilet runs", "flapper", "fill valve", "flush valve", "toilet repair", "fix toilet", "fix my toilet", "toilet tune"], trade: "plumbing", itemId: "toilet-repair-internals", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.faucet_repair", category: "Plumbing", keywords: ["faucet dripping", "dripping faucet", "faucet drips", "leaky faucet", "leaking faucet", "faucet leaking", "dripping tap", "tap dripping", "faucet cartridge", "faucet repair", "fix faucet", "drips constantly"], trade: "plumbing", itemId: "faucet-repair-cartridge", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.water_heater_repair", category: "Plumbing", keywords: ["no hot water", "not enough hot water", "water heater repair", "water heater not heating", "pilot light", "thermocouple", "hot water runs out", "runs out fast", "water heater making noise", "popping noise"], trade: "plumbing", itemId: "water-heater-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.toilet_reset", category: "Plumbing", keywords: ["toilet leaking at base", "leaking at base", "water around bottom of toilet", "puddle under toilet", "wax ring", "toilet wobbles", "toilet rocking", "toilet reset"], trade: "plumbing", itemId: "toilet-reset-wax-ring", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.shower_valve", category: "Plumbing", keywords: ["shower drips", "shower dripping", "shower valve", "shower cartridge", "shower handle", "tub faucet leaking", "no hot water in shower", "shower wont turn off", "shower won't turn off"], trade: "plumbing", itemId: "shower-valve-cartridge", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.garbage_disposal", category: "Plumbing", keywords: ["garbage disposal", "disposal jammed", "disposal humming", "disposal wont turn on", "insinkerator", "waste disposal", "disposer"], trade: "plumbing", itemId: "garbage-disposal-service", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.sump_pump", category: "Plumbing", keywords: ["sump pump", "sump pit", "basement flooding"], trade: "plumbing", itemId: "sump-pump-service", unit: "each", defaultQuantity: 1, priority: 1 },
  // A literal request to LOCATE a leak gets the diagnosis-only item; a SYMPTOM
  // ("water bill doubled", "wet spot on ceiling") gets the all-in find-and-fix,
  // because that person wants it repaired, not just found.
  { job_type: "plumbing.leak_detection", category: "Plumbing", keywords: ["leak detection", "locate the leak", "find the leak", "find a leak", "where is the leak", "slab leak detection"], trade: "plumbing", itemId: "leak-detection", unit: "hour", defaultQuantity: 2, priority: 1 },
  { job_type: "plumbing.hidden_leak", category: "Plumbing", keywords: ["hidden leak", "water bill", "water bill doubled", "high water bill", "wet spot on ceiling", "water spot on ceiling", "damp drywall", "water meter spinning", "water running in walls", "hear water running", "slab leak", "leak somewhere"], trade: "plumbing", itemId: "leak-find-and-fix", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.burst_pipe", category: "Plumbing", keywords: ["burst pipe", "pipe burst", "frozen pipe", "frozen pipes", "pipe cracked", "cracked pipe", "water spraying", "emergency plumber", "pipe leaking behind wall"], trade: "plumbing", itemId: "burst-pipe-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.tankless_water_heater", category: "Plumbing", keywords: ["tankless", "on-demand water heater"], trade: "plumbing", itemId: "tankless-water-heater-install", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "plumbing.fixture", category: "Plumbing", keywords: ["faucet", "toilet", "sink", "fixture"], trade: "plumbing", itemId: "fixture-install", unit: "each", defaultQuantity: 1, notIfContains: ["dripping", "drips", "keeps running", "running toilet", "wont stop", "won't stop", "leaking at base", "wax ring", "wobbles", "rocking", "cartridge", "flapper", "fill valve", "repair"] },
  { job_type: "plumbing.pipe_repair", category: "Plumbing", keywords: ["leak", "clog", "drain"], trade: "plumbing", itemId: "pipe-repair", unit: "project", defaultQuantity: 1 },
  { job_type: "plumbing.repipe", category: "Plumbing", keywords: ["repipe", "repiping"], trade: "plumbing", itemId: "whole-house-repipe-pex", unit: "sq ft", defaultQuantity: 1500 },
  { job_type: "plumbing.sewer_line", category: "Plumbing", keywords: ["sewer"], trade: "plumbing", itemId: "sewer-line-replacement", unit: "linear foot", defaultQuantity: 50 },

  // Electrical
  { job_type: "electrical.panel", category: "Electrical", keywords: ["panel upgrade", "electrical panel", "breaker panel", "200 amp"], trade: "electrical", itemId: "panel-upgrade-200amp", unit: "project", defaultQuantity: 1 },
  { job_type: "electrical.outlet", category: "Electrical", keywords: ["outlet", "socket"], trade: "electrical", itemId: "outlet-installation", unit: "each", defaultQuantity: 1, notIfContains: ["dead", "not working", "no power", "repair", "stopped working", "sparking", "burning smell", "gfci", "ground fault"] },
  { job_type: "electrical.ceiling_fan", category: "Electrical", keywords: ["ceiling fan"], trade: "electrical", itemId: "ceiling-fan-install", unit: "each", defaultQuantity: 1 },
  { job_type: "electrical.ev_charger", category: "Electrical", keywords: ["ev charger", "car charger"], trade: "electrical", itemId: "ev-charger-level2", unit: "each", defaultQuantity: 1 },
  { job_type: "electrical.rewire", category: "Electrical", keywords: ["rewire", "rewiring"], trade: "electrical", itemId: "whole-house-rewire", unit: "sq ft", defaultQuantity: 1500 },
  // Solar outranks "panel" (electrical.panel) and "light"/"power" — a solar
  // request must never price as a breaker panel. Default 20 panels ≈ 8 kW, the
  // median US residential system.
  { job_type: "electrical.solar", category: "Electrical", keywords: ["solar", "solar panel", "solar panels", "pv system", "photovoltaic"], trade: "electrical", itemId: "solar-panel-install", unit: "each", defaultQuantity: 20, priority: 1, notIfContains: ["repair", "fix", "clean", "cleaning", "inspect", "inspection", "maintenance", "remove", "removal"] },
  { job_type: "electrical.lighting", category: "Electrical", keywords: ["light", "lighting"], trade: "electrical", itemId: "light-fixture-install", unit: "each", defaultQuantity: 1, notIfContains: ["recessed", "can light", "can lights", "pot light", "downlight", "switch", "dimmer"] },
  // Electrical repairs and small jobs. Symptoms first: "breaker keeps tripping"
  // and "outlet not working" are how these arrive, and neither classified at all
  // before (2026-07-23).
  { job_type: "electrical.breaker", category: "Electrical", keywords: ["breaker", "breaker tripping", "keeps tripping", "circuit breaker", "fuse keeps blowing", "tripping"], trade: "electrical", itemId: "circuit-breaker-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "electrical.switch", category: "Electrical", keywords: ["switch", "light switch", "dimmer", "switch not working", "replace switch"], trade: "electrical", itemId: "switch-dimmer-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "electrical.gfci", category: "Electrical", keywords: ["gfci", "gfi", "ground fault", "bathroom outlet", "kitchen outlet"], trade: "electrical", itemId: "gfci-outlet", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "electrical.recessed", category: "Electrical", keywords: ["recessed", "can light", "can lights", "pot light", "downlight", "recessed lighting"], trade: "electrical", itemId: "recessed-light-install", unit: "each", defaultQuantity: 4, priority: 1 },
  { job_type: "electrical.detector", category: "Electrical", keywords: ["smoke detector", "smoke alarm", "carbon monoxide", "co detector", "chirping", "detector beeping"], trade: "electrical", itemId: "smoke-detector-install", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "electrical.dedicated_circuit", category: "Electrical", keywords: ["dedicated circuit", "new circuit", "240v", "220v", "dryer outlet", "range outlet", "subpanel"], trade: "electrical", itemId: "dedicated-circuit", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "electrical.doorbell", category: "Electrical", keywords: ["doorbell", "video doorbell", "ring doorbell", "nest doorbell"], trade: "electrical", itemId: "doorbell-install", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "electrical.outlet_repair", category: "Electrical", keywords: ["outlet not working", "dead outlet", "outlet no power", "outlet sparking", "outlet repair", "plug not working"], trade: "electrical", itemId: "outlet-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "electrical.diagnostic", category: "Electrical", keywords: ["troubleshoot", "troubleshooting", "electrical problem", "no power", "power out", "lights flickering", "flickering", "electrician diagnose"], trade: "electrical", itemId: "electrical-diagnostic", unit: "hour", defaultQuantity: 2, priority: 1 },
  { job_type: "electrical.surge_protector", category: "Electrical", keywords: ["surge protector", "whole house surge", "whole-house surge", "surge protection", "spd"], trade: "electrical", itemId: "surge-protector-install", unit: "each", defaultQuantity: 1, priority: 1 },
  // Multi-word keywords only — a bare "tv" would substring-match unrelated text.
  { job_type: "electrical.tv_mount", category: "Electrical", keywords: ["tv mount", "mount tv", "mount a tv", "mount the tv", "mounting tv", "mounting a tv", "install tv", "install a tv", "install the tv", "tv install", "tv wall", "tv on wall", "tv on the wall", "wall mount tv", "hang tv", "hang a tv", "hang the tv", "tv bracket", "television", "flat screen", "flatscreen"], trade: "electrical", itemId: "tv-mount-install", unit: "each", defaultQuantity: 1 },

  // Appliances (added 2026-07-22 — see the catalog block for why this is its
  // own category and not more Electrical/Plumbing rows).
  //
  // Repair and install are separate entries for the same appliance because
  // they are separate jobs at separate prices, and the word people type tells
  // you which: symptoms ("not draining", "won't start") mean repair, the bare
  // noun means the swap. Repair entries carry `priority: 1` so a symptom beats
  // the plain-noun install entry even when the install keyword is longer.
  //
  // Where only one direction is a real job, there is only one entry: a
  // refrigerator gets repaired (installing one is plugging it in), and a
  // microwave gets installed (a broken one is replaced, not repaired).
  { job_type: "appliances.dishwasher_repair", category: "Appliances", keywords: ["dishwasher repair", "repair dishwasher", "fix dishwasher", "fix my dishwasher", "dishwasher not draining", "dishwasher won't drain", "dishwasher wont drain", "dishwasher leaking", "dishwasher is leaking", "leaking dishwasher", "dishwasher not cleaning", "dishwasher not drying", "dishwasher won't start", "dishwasher wont start", "dishwasher broken", "broken dishwasher"], trade: "appliance", itemId: "dishwasher-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "appliances.dishwasher_install", category: "Appliances", keywords: ["dishwasher"], trade: "appliance", itemId: "dishwasher-install", unit: "each", defaultQuantity: 1 },
  { job_type: "appliances.refrigerator_repair", category: "Appliances", keywords: ["refrigerator", "fridge", "freezer", "ice maker", "icemaker"], trade: "appliance", itemId: "refrigerator-repair", unit: "each", defaultQuantity: 1 },
  { job_type: "appliances.washer_repair", category: "Appliances", keywords: ["washing machine", "washer repair", "repair washer", "fix washer", "fix my washer", "washer not draining", "washer not spinning", "washer won't spin", "washer wont spin", "washer leaking", "washer is leaking", "leaking washer", "washer won't start", "washer wont start"], trade: "appliance", itemId: "washer-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "appliances.dryer_repair", category: "Appliances", keywords: ["dryer repair", "repair dryer", "fix dryer", "fix my dryer", "dryer not heating", "dryer not drying", "dryer won't heat", "dryer wont heat", "dryer won't start", "dryer wont start", "dryer not spinning", "dryer takes forever"], trade: "appliance", itemId: "dryer-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  // "vent" alone belongs to HVAC — these are all multi-word for that reason.
  { job_type: "appliances.dryer_vent", category: "Appliances", keywords: ["dryer vent", "vent cleaning", "lint buildup", "lint trap", "clean the vent"], trade: "appliance", itemId: "dryer-vent-cleaning", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "appliances.oven_range_repair", category: "Appliances", keywords: ["oven repair", "repair oven", "fix oven", "fix my oven", "oven not heating", "oven won't heat", "oven wont heat", "stove repair", "fix stove", "stove not working", "range not heating", "burner not working", "burner won't light", "burner wont light", "cooktop repair", "oven won't turn on", "oven wont turn on"], trade: "appliance", itemId: "oven-range-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "appliances.range_install", category: "Appliances", keywords: ["install range", "install a range", "range install", "install stove", "install a stove", "stove install", "new stove", "install cooktop", "install a cooktop", "install oven", "install an oven", "install wall oven", "replace stove", "replace the stove"], trade: "appliance", itemId: "range-oven-install", unit: "each", defaultQuantity: 1 },
  { job_type: "appliances.washer_dryer_install", category: "Appliances", keywords: ["install washer", "install a washer", "install dryer", "install a dryer", "install washing machine", "washer dryer hookup", "washer hookup", "dryer hookup", "hook up washer", "hook up dryer", "hook up the washer", "hook up the dryer"], trade: "appliance", itemId: "washer-dryer-install", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "appliances.microwave_install", category: "Appliances", keywords: ["microwave"], trade: "appliance", itemId: "otr-microwave-install", unit: "each", defaultQuantity: 1 },

  // Mold & Pest Control
  // "mold" is word-boundary matched (see WORD_BOUNDARY_TERMS) — it sits inside
  // "molding", and "replace the crown molding" stem-matched this category long
  // before it had entries to land on.
  // 100 sq ft is the reference job: at $10–25/sq ft that spans the published
  // $1,100–3,400 average remediation, and the chat asks for the real area.
  { job_type: "mold.remediation", category: "Mold & Pest Control", keywords: ["mold", "molds", "moldy", "black mold", "mold remediation", "mold removal", "remove mold", "mold behind", "mold in the wall", "mold on drywall", "mold cleanup", "mold remedy", "remediate", "mildew"], trade: "remediation", itemId: "mold-remediation", unit: "sq ft", defaultQuantity: 100 },
  { job_type: "mold.inspection", category: "Mold & Pest Control", keywords: ["mold inspection", "mold test", "mold testing", "test for mold", "inspect for mold", "mold assessment", "air quality test", "spore count"], trade: "remediation", itemId: "mold-inspection", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "pest.termite", category: "Mold & Pest Control", keywords: ["termite", "termites", "wood destroying", "tenting", "fumigation", "fumigate"], trade: "pest", itemId: "termite-treatment", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "pest.rodent", category: "Mold & Pest Control", keywords: ["rodent", "rodents", "rat", "rats", "mice", "mouse", "bats in", "bat removal", "bat exclusion", "bat in the attic", "squirrel", "raccoon", "opossum", "possum", "exclusion"], trade: "pest", itemId: "rodent-exclusion", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "pest.bed_bugs", category: "Mold & Pest Control", keywords: ["bed bug", "bed bugs", "bedbug", "bedbugs"], trade: "pest", itemId: "bed-bug-treatment", unit: "each", defaultQuantity: 2, priority: 1 },
  { job_type: "pest.treatment", category: "Mold & Pest Control", keywords: ["pest control", "exterminator", "extermination", "exterminate", "infestation", "ant", "ants", "roach", "roaches", "cockroach", "spider", "spiders", "wasp", "wasps", "hornet", "bee", "bees", "flea", "fleas", "silverfish", "earwig", "bug", "bugs", "insect", "insects"], trade: "pest", itemId: "pest-treatment", unit: "each", defaultQuantity: 1 },
  { job_type: "pest.mosquito", category: "Mold & Pest Control", keywords: ["mosquito", "mosquitos", "mosquitoes", "tick", "ticks", "mosquito spraying", "yard spraying for bugs", "backyard bugs"], trade: "pest", itemId: "mosquito-treatment", unit: "project", defaultQuantity: 1, priority: 1 },

  // HVAC
  { job_type: "hvac.furnace", category: "HVAC", keywords: ["furnace"], trade: "hvac", itemId: "gas-furnace-installed", unit: "project", defaultQuantity: 1 },
  { job_type: "hvac.ac", category: "HVAC", keywords: ["central air", "air condition", "a/c"], trade: "hvac", itemId: "central-ac-installed", unit: "project", defaultQuantity: 1 },
  { job_type: "hvac.heat_pump", category: "HVAC", keywords: ["heat pump"], trade: "hvac", itemId: "heat-pump-installed", unit: "project", defaultQuantity: 1 },
  { job_type: "hvac.mini_split", category: "HVAC", keywords: ["mini split", "mini-split", "ductless"], trade: "hvac", itemId: "mini-split-per-zone", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.thermostat", category: "HVAC", keywords: ["thermostat"], trade: "hvac", itemId: "thermostat-installation-smart", unit: "each", defaultQuantity: 1, notIfContains: ["repair", "not working", "blank", "broken", "basic", "non-smart", "old thermostat"] },
  { job_type: "hvac.thermostat_repair", category: "HVAC", keywords: ["thermostat not working", "thermostat blank", "thermostat repair", "thermostat broken", "basic thermostat", "non-smart thermostat"], trade: "hvac", itemId: "thermostat-repair-basic", unit: "each", defaultQuantity: 1, priority: 1 },
  // The generic repair entry keeps ONLY the words that mean "something is wrong
  // and I can't name the part". Every specific symptom below outranks it, so
  // "AC not cooling" stops quoting a furnace job (reported 2026-07-23).
  { job_type: "hvac.repair", category: "HVAC", keywords: ["repair", "service"], trade: "hvac", itemId: "furnace-repair", unit: "project", defaultQuantity: 1, notIfContains: ["not cooling", "no cold air", "blowing warm", "blowing hot", "capacitor", "contactor", "refrigerant", "freon", "recharge", "blower", "condensate", "leaking water", "ignitor", "igniter", "flame sensor", "thermostat", "evaporator", "coil", "tune-up", "tune up", "maintenance"] },
  // HVAC symptom routing. People describe what the house is doing, not which
  // part failed, so the keywords are symptoms first and part names second.
  { job_type: "hvac.ac_repair", category: "HVAC", keywords: ["not cooling", "ac not cooling", "no cold air", "blowing warm", "blowing hot air", "ac broken", "ac not working", "air conditioner not working", "ac stopped"], trade: "hvac", itemId: "ac-repair-diagnostic", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.capacitor", category: "HVAC", keywords: ["capacitor", "contactor", "ac wont start", "ac won't start", "humming but not starting"], trade: "hvac", itemId: "ac-capacitor-contactor", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.refrigerant", category: "HVAC", keywords: ["refrigerant", "freon", "recharge", "low on refrigerant", "refrigerant leak"], trade: "hvac", itemId: "refrigerant-recharge", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.blower_motor", category: "HVAC", keywords: ["blower motor", "blower", "fan not blowing", "no air coming out"], trade: "hvac", itemId: "blower-motor-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.condensate", category: "HVAC", keywords: ["condensate", "ac leaking water", "water leaking from ac", "drain line clogged", "drip pan overflowing"], trade: "hvac", itemId: "condensate-drain-clearing", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.ignitor", category: "HVAC", keywords: ["ignitor", "igniter", "flame sensor", "furnace wont ignite", "furnace won't ignite", "furnace not igniting", "furnace wont start", "no heat"], trade: "hvac", itemId: "furnace-ignitor-sensor", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.evaporator_coil", category: "HVAC", keywords: ["evaporator coil", "evaporator", "coil replacement", "frozen coil", "iced up coil"], trade: "hvac", itemId: "evaporator-coil-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.tune_up", category: "HVAC", keywords: ["tune-up", "tune up", "maintenance", "seasonal service", "annual service", "hvac inspection"], trade: "hvac", itemId: "hvac-tune-up", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.compressor", category: "HVAC", keywords: ["compressor", "ac compressor", "compressor replacement", "compressor replacement cost"], trade: "hvac", itemId: "ac-compressor-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "hvac.duct_cleaning", category: "HVAC", keywords: ["duct cleaning", "clean the ducts", "clean air ducts", "air duct cleaning", "dusty vents"], trade: "hvac", itemId: "air-duct-cleaning", unit: "project", defaultQuantity: 1, priority: 1 },

  // Painting
  { job_type: "painting.ceiling", category: "Painting", keywords: ["paint ceiling", "paint the ceiling", "paint my ceiling", "ceiling paint", "paint ceilings"], trade: "paint", itemId: "paint-interior-labor", unit: "sq ft", defaultQuantity: 200, priority: 1 },
  { job_type: "painting.accent_wall", category: "Painting", keywords: ["accent wall", "feature wall", "one wall", "single wall", "paint a wall"], trade: "paint", itemId: "paint-interior-labor", unit: "sq ft", defaultQuantity: 120, priority: 1 },
  { job_type: "painting.interior", category: "Painting", keywords: ["interior", "room", "wall color", "repaint"], trade: "paint", itemId: "paint-interior-labor", unit: "sq ft", defaultQuantity: 250, notIfContains: ["water stain", "ceiling stain", "hole in", "nail pop", "drywall patch", "patch", "popcorn", "wallpaper", "pressure wash", "power wash", "trim", "baseboard", "crown molding", "deck"] },
  { job_type: "painting.exterior", category: "Painting", keywords: ["exterior"], trade: "paint", itemId: "paint-exterior-labor", unit: "sq ft", defaultQuantity: 1500, notIfContains: ["pressure wash", "power wash", "wash the house", "deck"] },
  { job_type: "painting.cabinet", category: "Painting", keywords: ["cabinet"], trade: "paint", itemId: "cabinet-painting-spray", unit: "linear foot", defaultQuantity: 20 },
  // Painting repairs / prep. These outrank the whole-repaint entries, which
  // otherwise catch "repaint" and "room" and quote a whole room for one patch.
  { job_type: "painting.ceiling_stain", category: "Painting", keywords: ["water stain", "ceiling stain", "stain on ceiling", "water spot", "ceiling spot", "stained ceiling", "water damage ceiling"], trade: "paint", itemId: "ceiling-stain-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "painting.drywall_patch", category: "Painting", keywords: ["drywall patch", "patch drywall", "hole in wall", "hole in the wall", "nail pop", "nail pops", "crack in wall", "wall crack", "patch and paint", "sheetrock patch"], trade: "paint", itemId: "drywall-patch-paint", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "painting.pressure_wash", category: "Painting", keywords: ["pressure wash", "pressure washing", "power wash", "power washing", "wash the house", "wash driveway"], trade: "paint", itemId: "pressure-washing", unit: "sq ft", defaultQuantity: 800, priority: 1 },
  { job_type: "painting.popcorn_removal", category: "Painting", keywords: ["popcorn ceiling", "popcorn removal", "remove popcorn", "acoustic ceiling", "textured ceiling removal"], trade: "paint", itemId: "popcorn-ceiling-removal", unit: "sq ft", defaultQuantity: 400, priority: 1 },
  { job_type: "painting.wallpaper_removal", category: "Painting", keywords: ["wallpaper", "remove wallpaper", "wallpaper removal", "strip wallpaper"], trade: "paint", itemId: "wallpaper-removal", unit: "sq ft", defaultQuantity: 400, priority: 1 },
  { job_type: "painting.trim", category: "Painting", keywords: ["trim", "baseboard", "baseboards", "crown molding", "molding", "paint trim"], trade: "paint", itemId: "trim-painting", unit: "linear foot", defaultQuantity: 120, priority: 1 },
  { job_type: "painting.door", category: "Painting", keywords: ["paint a door", "paint the door", "paint my front door", "paint front door", "paint garage door", "door painting", "repaint door"], trade: "paint", itemId: "door-painting", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "painting.exterior_peeling", category: "Painting", keywords: ["peeling", "flaking paint", "bubbling paint", "paint is peeling", "peeling paint", "scrape and repaint", "failing paint"], trade: "paint", itemId: "paint-exterior-labor", unit: "sq ft", defaultQuantity: 400, priority: 1 },
  { job_type: "painting.fence_stain", category: "Painting", keywords: ["stain my fence", "fence staining", "paint my fence", "fence painting", "seal fence", "stain the fence"], trade: "deck", itemId: "deck-refinish", unit: "sq ft", defaultQuantity: 200, priority: 1 },
  { job_type: "painting.touchup", category: "Painting", keywords: ["touch up", "touch-up", "touchup", "scuff", "scuff marks", "mark on wall", "marks on wall", "paint touch up"], trade: "paint", itemId: "drywall-patch-paint", unit: "each", defaultQuantity: 1, priority: 1 },
  // Deck staining is the SAME job as carpentry.deck_refinish and shares its
  // item — a deck contractor and a painter both do it at the same $2-5/sq ft.
  // It needs its own Painting-category entry because classification is scoped
  // by category: a user who tapped Painting never sees the Carpentry entries,
  // and would otherwise fall through to a per-sq-ft interior repaint.
  { job_type: "painting.deck_stain", category: "Painting", keywords: ["deck", "stain deck", "deck stain", "staining deck", "seal deck", "deck sealing", "restain deck"], trade: "deck", itemId: "deck-refinish", unit: "sq ft", defaultQuantity: 300, priority: 1 },

  // Carpentry
  // Build vs. repair. The bare "deck" entry means BUILD, so any repair word
  // has to veto it or "fix my deck" quotes new construction; the three repair
  // entries below carry priority 1 so they win outright when both match.
  { job_type: "carpentry.fence", category: "Carpentry", keywords: ["fence", "fence repair", "fence post", "leaning fence", "fence panel", "gate repair", "broken fence"], trade: "framing", itemId: "fence-repair", unit: "linear foot", defaultQuantity: 24, priority: 1 },
  { job_type: "carpentry.wood_rot", category: "Carpentry", keywords: ["wood rot", "dry rot", "rotted trim", "rotten trim", "rotted siding", "rotted sill", "fascia rot", "soffit rot", "fascia", "soffit", "soffit falling", "fascia board", "rotting wood"], trade: "framing", itemId: "wood-rot-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "carpentry.trim", category: "Carpentry", keywords: ["baseboard", "baseboards", "casing", "crown molding", "molding", "trim work", "install trim"], trade: "framing", itemId: "trim-carpentry", unit: "linear foot", defaultQuantity: 120, priority: 1 },
  { job_type: "carpentry.shelving", category: "Carpentry", keywords: ["shelving", "install shelves", "install shelf", "closet shelf", "closet shelves", "floating shelf", "floating shelves", "shelf install", "closet organizer"], trade: "framing", itemId: "shelving-install", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "carpentry.deck", category: "Carpentry", keywords: ["deck"], trade: "deck", itemId: "pressure-treated-installed", unit: "sq ft", defaultQuantity: 300, notIfContains: ["fix", "repair", "rot", "rotten", "rotted", "refinish", "resurface", "restain", "re-stain", "stain", "seal", "sand", "some boards", "few boards", "replace boards", "deck board", "loose", "wobbly", "squeak", "railing", "baluster", "baby proof", "babyproof", "baby-proof", "child proof", "childproof"] },
  { job_type: "carpentry.deck_boards", category: "Carpentry", keywords: ["deck board", "deck boards", "replace boards", "some boards", "few boards", "rotten boards", "rotted boards", "board replacement"], trade: "deck", itemId: "deck-board-replacement", unit: "each", defaultQuantity: 12, priority: 1 },
  { job_type: "carpentry.deck_refinish", category: "Carpentry", keywords: ["refinish", "refinishing", "resurface", "restain", "re-stain", "stain", "seal", "sealing", "sand"], trade: "deck", itemId: "deck-refinish", unit: "sq ft", defaultQuantity: 300, priority: 1 },
  { job_type: "carpentry.deck_railing", category: "Carpentry", keywords: ["railing", "railings", "guardrail", "baluster", "balusters", "baby proof", "babyproof", "baby-proof", "child proof", "childproof"], trade: "deck", itemId: "deck-railing", unit: "linear foot", defaultQuantity: 24, priority: 1 },
  { job_type: "carpentry.deck_repair", category: "Carpentry", keywords: ["deck repair", "repair deck", "fix deck", "fix my deck", "deck rot", "rotten deck", "wobbly deck", "loose deck"], trade: "deck", itemId: "deck-structural-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  // "vanity cabinet" (14 chars) outranks the generic "cabinet" (7) under
  // longest-keyword matching, so a vanity swap doesn't price as 15 linear
  // feet of kitchen cabinets.
  { job_type: "carpentry.vanity", category: "Carpentry", keywords: ["vanity cabinet", "vanity"], trade: "cabinetry", itemId: "bathroom-vanity-installation", unit: "each", defaultQuantity: 1 },
  { job_type: "carpentry.cabinet", category: "Carpentry", keywords: ["cabinet", "cabinetry"], trade: "cabinetry", itemId: "stock-cabinets-installed", unit: "linear foot", defaultQuantity: 15 },
  { job_type: "carpentry.squeaky_floor", category: "Carpentry", keywords: ["squeak", "squeaky floor", "creaky floor", "creaking floor", "floor squeaks", "squeaky stairs", "creaky stairs"], trade: "flooring", itemId: "squeaky-floor-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "carpentry.door_repair", category: "Carpentry", keywords: ["door wont close", "door won't close", "door sticking", "sticking door", "door stuck", "door wont latch", "door won't latch", "sagging door", "door rubs", "adjust the door", "door hinge", "gate wont close", "gate won't close", "gate repair", "sagging gate", "fix the gate"], trade: "doors", itemId: "door-adjustment", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "carpentry.framing", category: "Carpentry", keywords: ["framing", "frame a wall", "frame wall", "build a wall", "new wall", "partition wall", "stud wall", "beam", "header", "load bearing", "load-bearing"], trade: "framing", itemId: "wall-framing", unit: "linear foot", defaultQuantity: 20 },

  // Roofing
  // Material-specific replacements come before the generic project entry:
  // when the material is known and EPCI has a per-sq-ft installed price,
  // area × rate is a far tighter estimate than the whole-project band
  // ($5,900-$53,100 regardless of size). Declared first so a same-length
  // keyword tie ("shingle" vs "replace", both 7) resolves to the specific
  // entry. EPCI has no flat/membrane roofing item (verified 2026-07-06:
  // no TPO/EPDM/torch-down in any trade), so flat roofs classify to the
  // whole-project item — wide but real; revisit when a source covers it.
  { job_type: "roofing.shingle", category: "Roofing", keywords: ["shingle", "asphalt", "architectural"], trade: "roofing", itemId: "architectural-installed", unit: "sq ft", defaultQuantity: 1700, notIfContains: ["missing", "blown off", "came off", "damaged", "a few", "repair", "inspection", "flashing"] },
  { job_type: "roofing.metal", category: "Roofing", keywords: ["metal roof", "standing seam"], trade: "roofing", itemId: "metal-roofing-installed", unit: "sq ft", defaultQuantity: 1700, priority: 1 },
  { job_type: "roofing.flat", category: "Roofing", keywords: ["flat roof", "tpo", "epdm", "torch down", "membrane", "rolled roofing"], trade: "roofing", itemId: "roof-replacement-total", unit: "project", defaultQuantity: 1 },
  { job_type: "roofing.replacement", category: "Roofing", keywords: ["replace", "replacement", "new roof", "reroof"], trade: "roofing", itemId: "roof-replacement-total", unit: "project", defaultQuantity: 1 },
  { job_type: "roofing.repair", category: "Roofing", keywords: ["repair", "patch", "leak"], trade: "roofing", itemId: "roof-repair-patch", unit: "sq ft", defaultQuantity: 50 },
  { job_type: "roofing.gutter", category: "Roofing", keywords: ["gutter"], trade: "roofing", itemId: "gutter-install-aluminum", unit: "linear foot", defaultQuantity: 150, notIfContains: ["clean", "cleaning", "clogged", "overflowing", "repair", "sagging", "leaking seam", "downspout"] },
  // Roofing maintenance. These outrank the install and whole-roof entries,
  // which otherwise catch "gutter" and "shingle" and quote a reroof for a few
  // missing tabs (2026-07-23).
  { job_type: "roofing.gutter_cleaning", category: "Roofing", keywords: ["gutter cleaning", "clean gutters", "clean the gutters", "clogged gutter", "gutters overflowing", "gutters full"], trade: "roofing", itemId: "gutter-cleaning", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "roofing.gutter_repair", category: "Roofing", keywords: ["gutter repair", "repair gutter", "sagging gutter", "gutter leaking", "downspout", "gutter seam"], trade: "roofing", itemId: "gutter-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "roofing.shingle_repair", category: "Roofing", keywords: ["missing shingle", "missing shingles", "blown off", "shingles came off", "damaged shingle", "damaged shingles", "shingle repair", "replace a few shingles", "lost shingles"], trade: "roofing", itemId: "shingle-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "roofing.flashing", category: "Roofing", keywords: ["flashing", "chimney leak", "step flashing", "pipe boot", "vent boot"], trade: "roofing", itemId: "flashing-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "roofing.inspection", category: "Roofing", keywords: ["roof inspection", "inspect the roof", "inspect my roof", "roof certification", "roof condition"], trade: "roofing", itemId: "roof-inspection", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "roofing.tarp", category: "Roofing", keywords: ["roof tarp", "tarp the roof", "emergency tarp", "cover the roof", "roof leaking now"], trade: "roofing", itemId: "roof-tarp", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "roofing.cleaning", category: "Roofing", keywords: ["roof cleaning", "clean the roof", "moss on roof", "roof moss", "algae on roof", "black streaks roof"], trade: "roofing", itemId: "roof-cleaning", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "roofing.tile_repair", category: "Roofing", keywords: ["cracked roof tile", "cracked roof tiles", "slipped tile", "broken roof tile", "roof tile repair", "clay tile roof", "concrete tile roof"], trade: "roofing", itemId: "shingle-repair", unit: "project", defaultQuantity: 1, priority: 1 },

  // Flooring
  { job_type: "flooring.hardwood", category: "Flooring", keywords: ["hardwood"], trade: "flooring", itemId: "hardwood-installed", unit: "sq ft", defaultQuantity: 200, notIfContains: ["cracked", "broken", "chipped", "repair", "regrout", "grout", "loose tile", "squeak", "squeaky", "scratch", "scratches", "gouge", "re-stretch", "restretch", "wrinkle", "patch", "seam"] },
  { job_type: "flooring.laminate", category: "Flooring", keywords: ["laminate"], trade: "flooring", itemId: "laminate-installed", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "flooring.lvp", category: "Flooring", keywords: ["vinyl plank", "lvp"], trade: "flooring", itemId: "lvp-installed", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "flooring.carpet", category: "Flooring", keywords: ["carpet", "rug"], trade: "flooring", itemId: "carpet-installed", unit: "sq ft", defaultQuantity: 200, notIfContains: ["cracked", "broken", "chipped", "repair", "regrout", "grout", "loose tile", "squeak", "squeaky", "scratch", "scratches", "gouge", "re-stretch", "restretch", "wrinkle", "patch", "seam"] },
  { job_type: "flooring.tile", category: "Flooring", keywords: ["tile"], trade: "flooring", itemId: "tile-installed", unit: "sq ft", defaultQuantity: 150, notIfContains: ["cracked", "broken", "chipped", "repair", "regrout", "grout", "loose tile", "squeak", "squeaky", "scratch", "scratches", "gouge", "re-stretch", "restretch", "wrinkle", "patch", "seam"] },
  { job_type: "flooring.epoxy", category: "Flooring", keywords: ["epoxy", "garage floor coating", "floor coating", "garage floor", "polyaspartic", "concrete coating", "flake floor", "metallic floor", "coat the floor", "coat my garage"], trade: "flooring", itemId: "epoxy-floor-coating", unit: "sq ft", defaultQuantity: 450, priority: 1 },
  { job_type: "flooring.refinish", category: "Flooring", keywords: ["refinish", "refinishing", "sand"], trade: "flooring", itemId: "hardwood-refinishing", unit: "sq ft", defaultQuantity: 200, notIfContains: ["scratch", "scratches", "gouge", "spot repair", "a few boards", "damaged board"] },
  // Flooring REPAIRS. These outrank the whole-floor installs, which otherwise
  // catch "tile"/"carpet"/"hardwood" and quote a room for one cracked tile.
  { job_type: "flooring.tile_repair", category: "Flooring", keywords: ["cracked tile", "broken tile", "chipped tile", "loose tile", "tile repair", "replace a tile", "cracked tiles"], trade: "flooring", itemId: "tile-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "flooring.grout", category: "Flooring", keywords: ["grout", "regrout", "re-grout", "grout repair", "grout cracking", "grout sealing", "moldy grout"], trade: "flooring", itemId: "grout-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "flooring.carpet_repair", category: "Flooring", keywords: ["carpet repair", "re-stretch", "restretch", "carpet wrinkle", "carpet ripple", "carpet patch", "carpet seam", "loose carpet"], trade: "flooring", itemId: "carpet-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "flooring.squeak", category: "Flooring", keywords: ["squeak", "squeaky", "creaky floor", "creaking floor", "floor squeaks"], trade: "flooring", itemId: "squeaky-floor-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "flooring.subfloor", category: "Flooring", keywords: ["subfloor", "sub floor", "soft spot in floor", "spongy floor", "rotted subfloor"], trade: "flooring", itemId: "subfloor-repair", unit: "sq ft", defaultQuantity: 100, priority: 1 },
  { job_type: "flooring.leveling", category: "Flooring", keywords: ["floor leveling", "level the floor", "uneven floor", "self-leveling", "self level"], trade: "flooring", itemId: "floor-leveling", unit: "sq ft", defaultQuantity: 200, priority: 1 },
  { job_type: "flooring.hardwood_repair", category: "Flooring", keywords: ["scratched floor", "scratched hardwood", "gouge", "damaged board", "damaged boards", "replace a few boards", "hardwood repair", "water damaged floor"], trade: "flooring", itemId: "hardwood-spot-repair", unit: "project", defaultQuantity: 1, priority: 1 },

  // Windows & Doors
  { job_type: "windows_doors.window", category: "Windows & Doors", keywords: ["window replacement", "replace window", "new window", "window"], trade: "windows", itemId: "vinyl-window-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "windows_doors.bay_window", category: "Windows & Doors", keywords: ["bay window", "bow window"], trade: "windows", itemId: "bay-bow-window-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "windows_doors.casement_window", category: "Windows & Doors", keywords: ["casement"], trade: "windows", itemId: "casement-window-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "windows_doors.egress_window", category: "Windows & Doors", keywords: ["egress"], trade: "windows", itemId: "egress-window-installation", unit: "each", defaultQuantity: 1 },
  { job_type: "windows_doors.french_door", category: "Windows & Doors", keywords: ["french door"], trade: "doors", itemId: "french-door-installation", unit: "pair", defaultQuantity: 1 },
  { job_type: "windows_doors.sliding_door", category: "Windows & Doors", keywords: ["sliding door", "patio door", "sliding glass"], trade: "doors", itemId: "sliding-patio-door", unit: "each", defaultQuantity: 1, notIfContains: ["broken", "cracked", "foggy", "fogged", "stuck", "wont open", "won't open", "wont close", "won't close", "wont latch", "won't latch", "sticking", "sagging", "repair", "adjust", "hinge"] },
  { job_type: "windows_doors.exterior_door", category: "Windows & Doors", keywords: ["exterior door", "entry door", "front door"], trade: "doors", itemId: "exterior-door-steel", unit: "each", defaultQuantity: 1, notIfContains: ["broken", "cracked", "foggy", "fogged", "stuck", "wont open", "won't open", "wont close", "won't close", "wont latch", "won't latch", "sticking", "sagging", "repair", "adjust", "hinge"] },
  { job_type: "windows_doors.interior_door", category: "Windows & Doors", keywords: ["interior door", "closet door", "bedroom door"], trade: "doors", itemId: "interior-door-hollow-core", unit: "each", defaultQuantity: 1, notIfContains: ["broken", "cracked", "foggy", "fogged", "stuck", "wont open", "won't open", "wont close", "won't close", "wont latch", "won't latch", "sticking", "sagging", "repair", "adjust", "hinge"] },
  { job_type: "windows_doors.garage_door", category: "Windows & Doors", keywords: ["garage door"], trade: "doors", itemId: "garage-door-single", unit: "each", defaultQuantity: 1, notIfContains: ["spring", "cable", "wont open", "won't open", "off track", "opener", "repair", "broken"] },
  // Window + door REPAIRS. These outrank the replacement entries, which
  // otherwise catch "window"/"door" and quote a new unit for a stuck sash.
  { job_type: "windows_doors.glass_repair", category: "Windows & Doors", keywords: ["broken window", "cracked window", "broken pane", "cracked pane", "glass replacement", "replace the glass", "window glass", "foggy window", "fogged window", "failed seal", "condensation between"], trade: "windows", itemId: "window-glass-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "windows_doors.window_hardware", category: "Windows & Doors", keywords: ["window wont open", "window won't open", "window wont stay up", "window stuck", "stuck window", "sash cord", "window balance", "window crank", "hard to open window"], trade: "windows", itemId: "window-hardware-repair", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "windows_doors.door_repair", category: "Windows & Doors", keywords: ["door wont close", "door won't close", "door sticking", "sticking door", "door stuck", "door wont latch", "door won't latch", "sagging door", "door rubs", "door repair", "adjust the door", "door hinge"], trade: "doors", itemId: "door-adjustment", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "windows_doors.garage_spring", category: "Windows & Doors", keywords: ["garage door spring", "garage spring", "garage door cable", "garage door wont open", "garage door won't open", "garage door off track", "garage door broken"], trade: "doors", itemId: "garage-door-spring", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "windows_doors.storm_door", category: "Windows & Doors", keywords: ["storm door", "screen door", "install storm door", "install screen door"], trade: "doors", itemId: "storm-door-install", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "windows_doors.deadbolt", category: "Windows & Doors", keywords: ["deadbolt", "dead bolt", "door lock", "install a lock", "change the locks", "rekey", "handleset", "door handle"], trade: "doors", itemId: "deadbolt-lock", unit: "each", defaultQuantity: 1, priority: 1 },

  // Landscaping
  { job_type: "landscaping.lawn", category: "Landscaping", keywords: ["lawn", "sod", "grass"], trade: "landscaping", itemId: "sod-installation", unit: "sq ft", defaultQuantity: 1000, notIfContains: ["mow", "mowing", "cut the grass", "cleanup", "clean up", "leaves", "overgrown", "weeding"] },
  // Landscaping maintenance — the recurring work that is most of the trade.
  { job_type: "landscaping.mowing", category: "Landscaping", keywords: ["mow", "mowing", "mow the lawn", "cut the grass", "lawn service", "lawn maintenance"], trade: "landscaping", itemId: "lawn-mowing", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.cleanup", category: "Landscaping", keywords: ["yard cleanup", "clean up the yard", "overgrown", "leaf removal", "leaves", "yard waste", "debris removal", "spring cleanup", "fall cleanup"], trade: "landscaping", itemId: "yard-cleanup", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.hedge", category: "Landscaping", keywords: ["hedge", "hedges", "shrub", "shrubs", "bushes", "bush trimming", "prune shrubs"], trade: "landscaping", itemId: "hedge-trimming", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.tree_trim", category: "Landscaping", keywords: ["tree trimming", "trim tree", "trim my tree", "trim trees", "prune tree", "tree pruning", "cut back tree", "trim branches", "overhanging branches"], trade: "landscaping", itemId: "tree-trimming", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.sprinkler_repair", category: "Landscaping", keywords: ["sprinkler head", "sprinkler repair", "sprinkler broken", "sprinkler not working", "zone not working", "irrigation repair", "broken sprinkler"], trade: "landscaping", itemId: "sprinkler-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.stump", category: "Landscaping", keywords: ["stump grinding", "stump removal", "grind stump", "remove stump", "tree stump"], trade: "landscaping", itemId: "stump-grinding", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.drainage", category: "Landscaping", keywords: ["drainage", "french drain", "standing water", "yard flooding", "water pooling", "poor drainage", "water in my yard", "soggy yard"], trade: "landscaping", itemId: "yard-drainage", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.retaining_wall", category: "Landscaping", keywords: ["retaining wall", "retaining wall leaning", "retaining wall failing", "wall bulging", "leaning wall"], trade: "landscaping", itemId: "retaining-wall-repair", unit: "project", defaultQuantity: 1, priority: 1 },
  { job_type: "landscaping.tree", category: "Landscaping", keywords: ["tree"], trade: "landscaping", itemId: "tree-removal", unit: "each", defaultQuantity: 1, notIfContains: ["trim", "trimming", "prune", "pruning", "cut back", "branches"] },
  { job_type: "landscaping.irrigation", category: "Landscaping", keywords: ["irrigation", "sprinkler"], trade: "landscaping", itemId: "irrigation-system-per-zone", unit: "each", defaultQuantity: 1, notIfContains: ["repair", "broken", "not working", "head", "leaking"] },
  { job_type: "landscaping.patio", category: "Landscaping", keywords: ["patio", "hardscape", "paver"], trade: "landscaping", itemId: "paver-patio-installation", unit: "sq ft", defaultQuantity: 200 },
  { job_type: "landscaping.mulch", category: "Landscaping", keywords: ["mulch"], trade: "landscaping", itemId: "mulch-installation", unit: "cubic yard", defaultQuantity: 5 },

  // === Auto & moto ======================================================
  // Categories match autoCategoryItems in Brightglow/Models/Vertical.swift.
  // Keywords are deliberately vehicle-specific: several home categories own
  // the generic word ("repair", "paint", "glass", "window"), so an auto entry
  // has to carry the longer, unambiguous phrase to win longest-match. Where
  // both verticals could plausibly claim a word, the auto keyword includes the
  // vehicle noun ("car ac", "car window") so the home entry keeps the bare one.

  // Repair (mechanical + maintenance)
  { job_type: "auto.oil_change", category: "Repair", keywords: ["oil change", "oil and filter", "change the oil", "lube oil"], trade: "auto-repair", itemId: "oil-change-synthetic", unit: "each", defaultQuantity: 1 },
  // Rotors declared with the longer keywords so "pads and rotors" outranks the
  // pads-only entry; a bare "brake job" lands on pads.
  { job_type: "auto.brakes_pads_rotors", category: "Repair", keywords: ["pads and rotors", "brake pads and rotors", "rotors", "rotor replacement", "brake rotors"], trade: "auto-repair", itemId: "brake-pads-rotors-per-axle", unit: "axle", defaultQuantity: 1, priority: 1 },
  { job_type: "auto.brakes", category: "Repair", keywords: ["brake", "brakes", "brake pad", "brake job", "brake replacement"], trade: "auto-repair", itemId: "brake-pads-per-axle", unit: "axle", defaultQuantity: 1 },
  { job_type: "auto.battery", category: "Repair", keywords: ["battery", "car battery", "dead battery", "won't start battery"], trade: "auto-repair", itemId: "battery-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.alternator", category: "Repair", keywords: ["alternator"], trade: "auto-repair", itemId: "alternator-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.starter", category: "Repair", keywords: ["starter", "starter motor"], trade: "auto-repair", itemId: "starter-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.water_pump", category: "Repair", keywords: ["water pump"], trade: "auto-repair", itemId: "water-pump-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.radiator", category: "Repair", keywords: ["radiator", "overheating", "coolant leak"], trade: "auto-repair", itemId: "radiator-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.timing_belt", category: "Repair", keywords: ["timing belt", "timing chain", "cam belt"], trade: "auto-repair", itemId: "timing-belt-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.spark_plugs", category: "Repair", keywords: ["spark plug", "spark plugs", "ignition coil", "tune up", "tune-up"], trade: "auto-repair", itemId: "spark-plug-replacement", unit: "each", defaultQuantity: 1 },
  // "air conditioning recharge" is longer than HVAC's "air condition", so it
  // wins outright; "car ac" carries the short phrasing without colliding.
  { job_type: "auto.ac", category: "Repair", keywords: ["ac recharge", "a/c recharge", "air conditioning recharge", "car ac", "car a/c", "auto ac", "freon", "ac not cold", "car air conditioning"], trade: "auto-repair", itemId: "ac-recharge-auto", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.transmission_fluid", category: "Repair", keywords: ["transmission fluid", "transmission service", "transmission flush"], trade: "auto-repair", itemId: "transmission-fluid-change", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.catalytic_converter", category: "Repair", keywords: ["catalytic converter", "cat converter", "catalytic"], trade: "auto-repair", itemId: "catalytic-converter-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.oxygen_sensor", category: "Repair", keywords: ["oxygen sensor", "o2 sensor", "02 sensor"], trade: "auto-repair", itemId: "oxygen-sensor-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.exhaust", category: "Repair", keywords: ["muffler", "exhaust", "tailpipe", "loud exhaust"], trade: "auto-repair", itemId: "muffler-exhaust-repair", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.suspension", category: "Repair", keywords: ["strut", "struts", "shock absorber", "shocks", "suspension"], trade: "auto-repair", itemId: "strut-shock-per-axle", unit: "axle", defaultQuantity: 1 },
  { job_type: "auto.cv_axle", category: "Repair", keywords: ["cv axle", "cv joint", "axle shaft", "drive axle"], trade: "auto-repair", itemId: "cv-axle-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.fuel_pump", category: "Repair", keywords: ["fuel pump", "fuel injector"], trade: "auto-repair", itemId: "fuel-pump-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.clutch", category: "Repair", keywords: ["clutch"], trade: "auto-repair", itemId: "clutch-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.diagnostic", category: "Repair", keywords: ["check engine", "diagnostic", "engine light", "scan tool", "obd"], trade: "auto-repair", itemId: "auto-diagnostic-fee", unit: "each", defaultQuantity: 1 },

  // --- Repair, grouped by vehicle system -------------------------------
  // The 22 entries above grew flat and undifferentiated. Everything below is
  // added by SYSTEM so the gaps are visible at a glance: ENGINE, DRIVETRAIN,
  // SUSPENSION, COOLING, INSPECTION. The app's five Auto categories map to
  // BUSINESS types and deliberately do not change — this is organisation
  // inside Repair, not a new taxonomy level.

  // ENGINE
  { job_type: "auto.head_gasket", category: "Repair", keywords: ["head gasket", "blown head gasket", "white smoke exhaust", "coolant in oil", "milky oil"], trade: "auto-repair", itemId: "head-gasket-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  // DRIVETRAIN — the fluid change already exists; this is the actual repair.
  { job_type: "auto.transmission_rebuild", category: "Repair", keywords: ["transmission rebuild", "rebuild transmission", "transmission repair", "transmission slipping", "slipping transmission", "wont shift", "won't shift", "transmission replacement", "new transmission"], trade: "auto-repair", itemId: "transmission-rebuild", unit: "each", defaultQuantity: 1, priority: 1 },
  // SUSPENSION
  { job_type: "auto.wheel_bearing", category: "Repair", keywords: ["wheel bearing", "humming noise", "growling noise", "hub bearing"], trade: "auto-repair", itemId: "wheel-bearing-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "auto.control_arm", category: "Repair", keywords: ["control arm", "ball joint", "bushing", "clunking over bumps", "clunk over bumps"], trade: "auto-repair", itemId: "control-arm-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  // COOLING — the ENGINE thermostat. Nothing to do with the HVAC one, and the
  // vertical guard keeps a house thermostat from ever landing here.
  { job_type: "auto.thermostat", category: "Repair", keywords: ["thermostat", "overheating", "engine overheating", "running hot", "temperature gauge"], trade: "auto-repair", itemId: "auto-thermostat-replacement", unit: "each", defaultQuantity: 1, priority: 1 },
  // INSPECTION — high volume, and entirely absent before. Smog is mandatory
  // biennially in California and on most private sales.
  { job_type: "auto.smog_check", category: "Repair", keywords: ["smog", "smog check", "smog test", "emissions test", "emissions check", "star station"], trade: "auto-repair", itemId: "smog-check", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "auto.pre_purchase_inspection", category: "Repair", keywords: ["pre purchase inspection", "pre-purchase inspection", "ppi", "inspect before buying", "buying a used car", "used car inspection"], trade: "auto-repair", itemId: "pre-purchase-inspection", unit: "each", defaultQuantity: 1, priority: 1 },
  // Moto-only job — no car equivalent, so it points straight at the moto item
  // rather than going through MOTO_VARIANTS. "timing chain" (12 chars) still
  // outranks "chain" (5), so a car timing job is unaffected.
  { job_type: "auto.chain_sprocket", category: "Repair", keywords: ["chain and sprocket", "chain & sprocket", "sprocket", "drive chain", "chain replacement"], trade: "moto-repair", itemId: "moto-chain-sprocket", unit: "each", defaultQuantity: 1 },

  // Tires
  // Bare noun phrasings ("motorcycle tires", "place tires on the bike") carry
  // no verb, and requiring one sent them to a labor-only fallback — reported
  // live 2026-07-20. "tire"/"tires" are word-boundary matched so they cannot
  // fire inside "entire". Longer keywords on the rotation / flat / TPMS /
  // alignment entries still outrank the bare noun.
  { job_type: "auto.tire_replacement", category: "Tires", keywords: ["new tire", "new tires", "tire replacement", "replace tire", "replace tires", "buy tires", "set of tires", "tire", "tires"], trade: "auto-tires", itemId: "tire-replacement-per-tire", unit: "each", defaultQuantity: 4 },
  { job_type: "auto.tire_mount_balance", category: "Tires", keywords: ["mount and balance", "mount & balance", "tire balancing", "balance tires"], trade: "auto-tires", itemId: "tire-mount-balance-per-tire", unit: "each", defaultQuantity: 4 },
  { job_type: "auto.tire_rotation", category: "Tires", keywords: ["tire rotation", "rotate tires", "rotate my tires"], trade: "auto-tires", itemId: "tire-rotation", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.flat_repair", category: "Tires", keywords: ["flat tire", "flat repair", "puncture", "nail in tire", "patch tire"], trade: "auto-tires", itemId: "flat-tire-repair", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.alignment", category: "Tires", keywords: ["alignment", "wheel alignment", "front end alignment", "pulling to one side"], trade: "auto-tires", itemId: "wheel-alignment", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.tpms", category: "Tires", keywords: ["tpms", "tire pressure sensor", "tire sensor"], trade: "auto-tires", itemId: "tpms-sensor-per-wheel", unit: "each", defaultQuantity: 1 },

  // Cleaning & Detailing
  { job_type: "auto.full_detail", category: "Cleaning & Detailing", keywords: ["full detail", "detailing", "detail my car", "car detail", "auto detail", "complete detail"], trade: "auto-detailing", itemId: "full-detail", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.interior_detail", category: "Cleaning & Detailing", keywords: ["interior detail", "interior cleaning", "shampoo seats", "clean the interior", "steam clean interior"], trade: "auto-detailing", itemId: "interior-detail", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.exterior_detail", category: "Cleaning & Detailing", keywords: ["exterior detail", "wax", "waxing", "buff and wax", "polish"], trade: "auto-detailing", itemId: "exterior-detail-wax", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.car_wash", category: "Cleaning & Detailing", keywords: ["car wash", "wash my car", "hand wash"], trade: "auto-detailing", itemId: "car-wash-basic", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.ceramic_coating", category: "Cleaning & Detailing", keywords: ["ceramic coating", "ceramic", "paint protection film", "ppf", "sealant"], trade: "auto-detailing", itemId: "ceramic-coating", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.headlight_restoration", category: "Cleaning & Detailing", keywords: ["headlight restoration", "foggy headlight", "cloudy headlight", "restore headlights"], trade: "auto-detailing", itemId: "headlight-restoration", unit: "pair", defaultQuantity: 1 },
  { job_type: "auto.paint_correction", category: "Cleaning & Detailing", keywords: ["paint correction", "swirl marks", "buff out scratches"], trade: "auto-detailing", itemId: "paint-correction", unit: "each", defaultQuantity: 1 },

  // Body & Paint
  { job_type: "auto.bumper_repair", category: "Body & Paint", keywords: ["bumper repair", "bumper scuff", "scuffed bumper", "scratched bumper", "bumper scratch"], trade: "auto-body", itemId: "bumper-repair-scuff", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.bumper_replacement", category: "Body & Paint", keywords: ["bumper replacement", "replace bumper", "new bumper", "bumper"], trade: "auto-body", itemId: "bumper-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.dent", category: "Body & Paint", keywords: ["dent", "ding", "paintless dent", "pdr", "hail damage"], trade: "auto-body", itemId: "pdr-dent-repair", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.panel_respray", category: "Body & Paint", keywords: ["respray", "repaint a panel", "panel paint", "paint one panel", "door paint", "fender paint"], trade: "auto-body", itemId: "panel-respray", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.full_respray", category: "Body & Paint", keywords: ["full respray", "paint my car", "repaint my car", "whole car paint", "paint the whole car", "car paint job"], trade: "auto-body", itemId: "full-respray", unit: "each", defaultQuantity: 1 },
  // "wrap" alone means the full job; partial and removal carry priority 1 and
  // also veto the full entry, so "removing an old wrap" can never quote a
  // whole colour change.
  { job_type: "auto.wrap_full", category: "Body & Paint", keywords: ["wrap", "car wrap", "wrap car", "wrap my car", "vinyl wrap", "full wrap", "colour change wrap", "color change wrap", "wrapping"], trade: "auto-body", itemId: "vehicle-wrap-full", unit: "each", defaultQuantity: 1, notIfContains: ["partial wrap", "panel wrap", "half wrap", "hood wrap", "roof wrap", "remove", "removal", "removing", "strip", "take off"] },
  { job_type: "auto.wrap_partial", category: "Body & Paint", keywords: ["partial wrap", "panel wrap", "half wrap", "hood wrap", "roof wrap", "accent wrap", "chrome delete"], trade: "auto-body", itemId: "vehicle-wrap-partial", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "auto.wrap_removal", category: "Body & Paint", keywords: ["wrap removal", "remove wrap", "remove the wrap", "removing wrap", "removing an old wrap", "take off wrap", "strip wrap", "old wrap"], trade: "auto-body", itemId: "vehicle-wrap-removal", unit: "each", defaultQuantity: 1, priority: 1 },
  { job_type: "auto.collision", category: "Body & Paint", keywords: ["collision", "accident damage", "fender bender", "body damage", "quarter panel", "replace fender", "replace door skin"], trade: "auto-body", itemId: "collision-panel-replacement", unit: "each", defaultQuantity: 1 },

  // Glass
  { job_type: "auto.windshield_replacement", category: "Glass", keywords: ["windshield replacement", "replace windshield", "new windshield", "windshield", "windscreen", "cracked windshield"], trade: "auto-glass", itemId: "windshield-replacement", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.chip_repair", category: "Glass", keywords: ["chip repair", "windshield chip", "rock chip", "star crack", "windshield crack repair"], trade: "auto-glass", itemId: "windshield-chip-repair", unit: "each", defaultQuantity: 1 },
  { job_type: "auto.adas", category: "Glass", keywords: ["adas", "recalibration", "camera calibration", "lane keep calibration"], trade: "auto-glass", itemId: "adas-recalibration", unit: "each", defaultQuantity: 1 },
  // "car window" / "door glass" keep the bare "window" for the home entry.
  { job_type: "auto.side_window", category: "Glass", keywords: ["car window", "side window", "door glass", "rear window", "quarter glass", "auto glass"], trade: "auto-glass", itemId: "side-window-replacement", unit: "each", defaultQuantity: 1 },
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
  "Appliances": { job_type: "appliances.general", category: "Appliances", keywords: [], trade: "appliance", itemId: "appliance-labor-hourly", unit: "hour", defaultQuantity: 2 },
  "HVAC": { job_type: "hvac.general", category: "HVAC", keywords: [], trade: "hvac", itemId: "hvac-labor-rate", unit: "hour", defaultQuantity: 2 },
  "Painting": { job_type: "painting.general", category: "Painting", keywords: [], trade: "paint", itemId: "paint-interior-labor", unit: "sq ft", defaultQuantity: 250 },
  "Carpentry": { job_type: "carpentry.general", category: "Carpentry", keywords: [], trade: "framing", itemId: "framing-labor-rate", unit: "sq ft", defaultQuantity: 200 },
  "Roofing": { job_type: "roofing.general", category: "Roofing", keywords: [], trade: "roofing", itemId: "roof-repair-patch", unit: "sq ft", defaultQuantity: 50 },
  "Flooring": { job_type: "flooring.general", category: "Flooring", keywords: [], trade: "flooring", itemId: "laminate-installed", unit: "sq ft", defaultQuantity: 200 },
  "Windows & Doors": { job_type: "windows_doors.general", category: "Windows & Doors", keywords: [], trade: "windows", itemId: "vinyl-window-replacement", unit: "each", defaultQuantity: 1 },
  "Landscaping": { job_type: "landscaping.general", category: "Landscaping", keywords: [], trade: "landscaping", itemId: "mulch-installation", unit: "cubic yard", defaultQuantity: 3 },
  // Was `null` ("no EPCI trade at all") until 2026-07-22. That reasoning came
  // from the dormant EPCI branch; the in-house catalog needs only hours,
  // materials and an anchor, all of which this trade has.
  "Mold & Pest Control": { job_type: "mold_pest.general", category: "Mold & Pest Control", keywords: [], trade: "remediation", itemId: "remediation-hourly", unit: "hour", defaultQuantity: 2 },
  // Auto & moto. "Repair" falls back to the posted door rate x a typical visit,
  // the same honest shape plumbing/electrical use. The other four fall back to
  // their most-requested job rather than an hourly rate: nobody buys detailing
  // or glass by the hour, so an hourly band would be a number the market
  // doesn't quote.
  "Repair": { job_type: "auto.general", category: "Repair", keywords: [], trade: "auto-repair", itemId: "auto-labor-hourly", unit: "hour", defaultQuantity: 2 },
  "Tires": { job_type: "auto.tires_general", category: "Tires", keywords: [], trade: "auto-tires", itemId: "tire-replacement-per-tire", unit: "each", defaultQuantity: 4 },
  "Cleaning & Detailing": { job_type: "auto.detailing_general", category: "Cleaning & Detailing", keywords: [], trade: "auto-detailing", itemId: "full-detail", unit: "each", defaultQuantity: 1 },
  "Body & Paint": { job_type: "auto.body_general", category: "Body & Paint", keywords: [], trade: "auto-body", itemId: "panel-respray", unit: "each", defaultQuantity: 1 },
  "Glass": { job_type: "auto.glass_general", category: "Glass", keywords: [], trade: "auto-glass", itemId: "windshield-replacement", unit: "each", defaultQuantity: 1 },
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
  // Not "appliance" — the stem has to catch the singular and the plural, and
  // people write both ("appliance repair", "my appliances").
  "Appliances": ["applianc"],
  "HVAC": ["hvac"],
  "Painting": ["paint"],
  // "deck" is unambiguously carpentry and is the word people actually type —
  // without it "refinish my deck" had no stem at all and the global scan handed
  // it to flooring's "refinish" (hardwood floors), 2026-07-22.
  "Carpentry": ["carpent", "deck"],
  "Roofing": ["roof"],
  "Flooring": ["floor"],
  "Windows & Doors": ["window", "door"],
  "Landscaping": ["landscap", "yard", "garden"],
  // "termite" earns a stem because the pests live in the things other
  // categories own: "we have termites in the deck" matched only Carpentry's
  // "deck" stem and quoted a $14,561 deck rebuild (2026-07-22). With both
  // stems hit, the pool spans both categories and "termite" (7) outranks
  // "deck" (4) on length. "mold" is word-boundary matched — see
  // WORD_BOUNDARY_TERMS — so it no longer hijacks "crown molding".
  "Mold & Pest Control": ["pest", "mold", "termite"],
  // Auto stems are narrow on purpose. "Repair" and "Body & Paint" get NO stem:
  // their category words ("repair", "paint") are owned by the home taxonomy,
  // and a stem here would hijack "repair my roof" / "paint the kitchen". Those
  // two categories reach their entries through vehicle-specific job keywords
  // instead. "Glass" stems on "windshield"/"windscreen" rather than "glass",
  // which appears in the home "sliding glass" door phrasing.
  "Tires": ["tire", "tires", "tyre", "tyres"],
  "Cleaning & Detailing": ["detail"],
  "Glass": ["windshield", "windscreen"],
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

export type Vehicle = "auto" | "moto";
export type Vertical = "home" | "auto";

/** App categories belonging to the Auto & moto vertical (see
 *  autoCategoryItems in Brightglow/Models/Vertical.swift). */
export const AUTO_CATEGORIES = new Set([
  "Repair",
  "Tires",
  "Cleaning & Detailing",
  "Body & Paint",
  "Glass",
]);

/** Which vertical a taxonomy entry belongs to. Derived from its category so it
 *  can't drift from the taxonomy the way a hand-maintained flag would. */
export function verticalForEntry(entry: JobTypeEntry): Vertical {
  return AUTO_CATEGORIES.has(entry.category) ? "auto" : "home";
}

// Words that name the vehicle rather than the job. Two jobs for them:
//
//  1. They're the vehicle signal when the client doesn't send one (typed
//     search: "new tires for my motorcycle").
//  2. They're STRIPPED before keyword matching. Keyword matching is plain
//     substring, so an interposed word silently breaks a match: "replace
//     motorcycle tires" does not contain "replace tires", so it missed the
//     tire entry entirely and fell through to a category-general labor-only
//     figure ($183 for a job that's ~$440). Removing the vehicle noun makes
//     the phrase match the base keyword again.
//
// "car"/"truck" are deliberately NOT here: several auto keywords deliberately
// embed them ("car wash", "car ac", "car window") to avoid colliding with the
// home taxonomy, and stripping would break those.
const MOTO_WORDS = [
  "motorcycle", "motorbike", "moto", "scooter", "dirt bike", "dirtbike",
  "harley", "sportbike", "sport bike",
];

/** The vehicle the words name, or null when they don't say. */
export function detectVehicle(description: string): Vehicle | null {
  const t = ` ${description.toLowerCase()} `;
  return MOTO_WORDS.some((w) => t.includes(w)) ? "moto" : null;
}

/** Description with vehicle nouns removed, so job keywords match again. */
export function stripVehicleWords(description: string): string {
  let t = description.toLowerCase();
  for (const w of MOTO_WORDS) t = t.split(w).join(" ");
  return t.replace(/\s+/g, " ").trim();
}

/** Auto item → its motorcycle equivalent. Applied after classification when
 *  the request is for a motorcycle: the taxonomy stays single-vehicle (one
 *  entry per job) and the swap happens at pricing time. defaultQuantity is
 *  remapped too — the count differs, most obviously for tires: a car set is 4,
 *  a bike's is 2. Jobs absent from this map keep the auto item on purpose. */
export const MOTO_VARIANTS: Record<
  string,
  { itemId: string; trade: string; defaultQuantity?: number }
> = {
  "tire-replacement-per-tire": { itemId: "moto-tire-replacement-per-tire", trade: "moto-tires", defaultQuantity: 2 },
  "tire-mount-balance-per-tire": { itemId: "moto-tire-mount-balance-per-tire", trade: "moto-tires", defaultQuantity: 2 },
  "oil-change-synthetic": { itemId: "moto-oil-change", trade: "moto-repair", defaultQuantity: 1 },
  "brake-pads-per-axle": { itemId: "moto-brake-pads-per-wheel", trade: "moto-repair", defaultQuantity: 1 },
  "brake-pads-rotors-per-axle": { itemId: "moto-brake-pads-per-wheel", trade: "moto-repair", defaultQuantity: 1 },
};

/** The entry to price for a motorcycle request — the moto variant when one
 *  exists, otherwise the original (auto item is the honest default). */
export function applyMotoVariant(entry: JobTypeEntry): JobTypeEntry {
  const v = MOTO_VARIANTS[entry.itemId];
  if (!v) return entry;
  return {
    ...entry,
    itemId: v.itemId,
    trade: v.trade,
    defaultQuantity: v.defaultQuantity ?? entry.defaultQuantity,
  };
}

export function classifyJobType(
  category: string,
  description: string,
  photoAttributes: string[] = [],
  /** Constrains matching to one vertical. Without it, the home taxonomy owns
   *  the bare words ("window", "paint", "door") and silently swallows vehicle
   *  requests: "Replace rear left quarter window" classified as a home vinyl
   *  window and quoted $860 of house glazing for a car window (reported live
   *  2026-07-20). A cross-vertical miss is the worst kind — not just the wrong
   *  job, the wrong trade entirely — so when the vertical is known, enforce
   *  it rather than hoping longest-match lands right. */
  vertical: Vertical | null = null,
): JobTypeEntry | null {
  const text = [description, ...photoAttributes].join(", ").toLowerCase();
  if (vertical && !category) {
    const scoped = JOB_TYPE_TAXONOMY.filter((e) => verticalForEntry(e) === vertical);
    const hit = longestKeywordMatch(scoped, text, true);
    if (hit) return hit;
    // No specific match inside the right vertical. Fall through to the normal
    // path ONLY for home; for a vehicle request, crossing into the home
    // taxonomy is exactly the failure this parameter exists to stop.
    if (vertical === "auto") return null;
  }
  if (category) {
    // Longest keyword wins, not first-declared: "replace 2 french door
    // windows" must land on french_door via "french door", not on the
    // generic window entry via "window".
    const candidates = JOB_TYPE_TAXONOMY.filter((entry) => entry.category === category);
    const specific = longestKeywordMatch(candidates, text);
    if (specific) return specific;
    return CATEGORY_GENERAL[category] ?? null;
  }

  // No category from the client — infer it from the description. A single
  // category-stem hit routes through the normal per-category path above, so
  // "fix my roof" still lands on a real number via the category-general
  // entry even when no job keyword matches.
  const stemmed = Object.keys(CATEGORY_STEMS)
    .filter((cat) => CATEGORY_STEMS[cat].some((s) => termMatches(text, s)));
  if (stemmed.length === 1) return classifyJobType(stemmed[0], description, photoAttributes);

  // No stem (or several) — scan job keywords, longest match wins as the
  // most specific ("water heater" beats "heater"-less generics). With no
  // category signal at all, within-category-only keywords are skipped;
  // when stems narrowed the pool they're safe to use again.
  const pool = stemmed.length > 0
    ? JOB_TYPE_TAXONOMY.filter((entry) => stemmed.includes(entry.category))
    : JOB_TYPE_TAXONOMY;
  return longestKeywordMatch(pool, text, stemmed.length === 0);
}

// Terms whose bare form appears INSIDE unrelated words — "tire" sits in
// "entire", so a plain substring test routes "replace the entire window" and
// "redo the entire roof" to the Tires category. These match a whole word only.
// Everything else stays substring-matched, which is load-bearing elsewhere
// (the "paint" stem has to catch "repaint", "floor" has to catch "flooring").
// "roof" sits inside "proof": "fix deck, replace shone decks and baby proof"
// stem-matched Roofing and priced a whole roof replacement for a deck repair
// (reported 2026-07-22). "baby proof", "waterproof", "soundproof" and
// "proofing" are all common in real requests, so this one has to be a word.
const WORD_BOUNDARY_TERMS = new Set([
  "tire", "tires", "tyre", "tyres", "roof", "roofs",
  // Mold & Pest, added with the category 2026-07-22. Every one of these is a
  // short word that lives inside a common unrelated one, and this category is
  // uniquely exposed to it: "mold" in "molding" (crown molding is CARPENTRY,
  // and it stem-matched Mold & Pest even before the category could price),
  // "ant" in "plant"/"want"/"basement", "rat" in "aerate"/"decorative",
  // "bee" in "been", "bug" in "debug", "mice" in "mice" only but kept for
  // symmetry with "mouse" in "mousehole".
  "mold", "molds", "ant", "ants", "rat", "rats", "bee", "bees",
  "bug", "bugs", "mice", "mouse", "flea", "fleas",
  // Not mine, found while testing the above: auto.dent's "ding" sits inside
  // "molding", "siding", "building", "sanding", "welding", "grinding". With no
  // category stem to narrow the pool, "replace the crown molding" classified as
  // paintless dent repair on a car (2026-07-22).
  "ding", "dings",
]);

/** Does `text` contain `term`, respecting word boundaries where required? */
export function termMatches(text: string, term: string): boolean {
  if (!WORD_BOUNDARY_TERMS.has(term)) return text.includes(term);
  return new RegExp(`\\b${term}\\b`).test(text);
}

function longestKeywordMatch(
  pool: JobTypeEntry[],
  text: string,
  excludeWithinCategoryOnly = false,
): JobTypeEntry | null {
  let best: JobTypeEntry | null = null;
  let bestLen = 0;
  let bestPriority = -1;
  for (const entry of pool) {
    if (entry.notIfContains?.some((w) => termMatches(text, w))) continue;
    const priority = entry.priority ?? 0;
    for (const kw of entry.keywords) {
      if (excludeWithinCategoryOnly && WITHIN_CATEGORY_ONLY.has(kw)) continue;
      if (!termMatches(text, kw)) continue;
      // Priority outranks length; length breaks ties within a priority.
      if (priority > bestPriority || (priority === bestPriority && kw.length > bestLen)) {
        best = entry;
        bestLen = kw.length;
        bestPriority = priority;
      }
    }
  }
  return best;
}

// Spelled-out counts up to twelve → digits, as their own words only, so
// "two windows" → "2 windows" but "twelve" inside another token is left alone.
// Kept small: past twelve, people write digits.
const SPELLED_NUMBERS: Record<string, string> = {
  one: "1", two: "2", three: "3", four: "4", five: "5", six: "6",
  seven: "7", eight: "8", nine: "9", ten: "10", eleven: "11", twelve: "12",
};
function spellOutToDigits(text: string): string {
  return text.replace(
    /\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b/g,
    (w) => SPELLED_NUMBERS[w],
  );
}

/** The nouns the quantity parser can count. Exported because the clarifying
 *  chat's prompt is built from this list: a question like "how many boards?"
 *  is only worth asking if the answer lands on a lever the engine reads. When
 *  the two drifted, the chat collected "20 deck boards" and the price did not
 *  move at all (2026-07-22). Add a noun here when you add an each-priced item.
 *  "vanity" is handled alongside these but spelled separately — its plural is
 *  irregular, so it can't take the shared `s?` suffix. */
export const COUNTABLE_NOUNS = [
  "window", "door", "outlet", "socket", "fan", "fixture", "light", "toilet",
  "faucet", "sink", "tree", "zone", "charger", "thermostat", "panel", "board",
  // Tires are per-unit and the count is the whole price: without this every
  // "replace 2 tires" fell back to the 4-tire default and quoted double
  // (2026-07-22). The car/moto defaults still cover an unstated count.
  "tire",
] as const;

const COUNTABLE = COUNTABLE_NOUNS.join("|");

// A number followed by a measurement unit is a dimension, not a count — "36
// inch bathroom vanity" priced as 36 vanities before this lookahead.
const NOT_A_MEASUREMENT =
  `(?!\\s*(?:["\u201d']|-?\\s*(?:in|inch|inches|ft|foot|feet|gal|gallon|amp)\\b))`;
const COUNT_BEFORE_NOUN = new RegExp(
  `(?:^|[\\s,])(\\d{1,2})${NOT_A_MEASUREMENT}\\s+(?:[a-z/-]+\\s+){0,3}?(?:(?:${COUNTABLE})s?|vanit(?:y|ies))\\b`,
);
// The noun must start on a word boundary, or it matches the tail of a longer
// word \u2014 "tire" sits in "entire", so "entire 3 rooms" read as 3 tires.
const COUNT_AFTER_NOUN = new RegExp(
  `\\b(?:${COUNTABLE})s?\\s*(?:[,:;-]|\\bx\\b)?\\s*(\\d{1,2})(?!\\s*[x\u00d7]\\s*\\d)${NOT_A_MEASUREMENT}\\b`,
);

// Explicit quantity beats the taxonomy default — the default is a real
// number too, just a rougher one, reflected in the caller's confidence level
// (see index.ts).
export function resolveQuantity(
  entry: JobTypeEntry,
  description: string,
): { quantity: number; isDefaulted: boolean } {
  // A project-priced item is the whole job — never scale it by a size the
  // user mentioned. "replace flat roof 1070 sq ft" must not multiply the
  // whole-project roof-replacement price by 1070 (produced a $6.3M-$56.8M
  // "estimate", verified live 2026-07-06).
  if (entry.unit === "project") {
    return { quantity: 1, isDefaulted: false };
  }
  if (entry.unit === "each" || entry.unit === "pair") {
    // Solar is the one item people size in system watts rather than in units
    // ("6.5 kW system", "10kw array"). Convert at a 400 W panel — the current
    // residential norm — so the two phrasings price the same array.
    if (entry.itemId === "solar-panel-install") {
      const kw = description.toLowerCase().match(
        /(\d{1,2}(?:\.\d)?)\s*(kw|kilowatt)/,
      );
      if (kw) {
        const panels = Math.round((Number(kw[1]) * 1000) / 400);
        if (panels > 0) return { quantity: panels, isDefaulted: false };
      }
    }
    // Explicit pair counts win outright for pair-priced items — "2 pairs of
    // french doors" is 2 units, no halving. This is the canonical phrasing
    // the clarify chat emits once the user resolves panels-vs-pairs.
    if (entry.unit === "pair") {
      const pairs = description.toLowerCase().match(/(?:^|[\s,])(\d{1,2})\s+pairs?\b/);
      if (pairs) {
        const value = Number(pairs[1]);
        if (value > 0) return { quantity: value, isDefaulted: false };
      }
    }
    // A small count within a few words of a countable noun: "2 french door
    // windows", "install 4 outlets", "2 vanities" (irregular plural, can't
    // take the generic "s?" suffix like the rest). The count must be its own
    // word, so dimension strings ("72x88") never match; a number followed by
    // a measurement unit is a dimension, not a count — "36 inch bathroom
    // vanity" priced as 36 vanities before the lookahead (caught 2026-07-15
    // by the in-house engine's end-to-end test). Spelled-out small numbers
    // ("two windows") are normalized to digits first so they count too.
    const normalized = spellOutToDigits(description.toLowerCase());
    const count = normalized.match(COUNT_BEFORE_NOUN);
    // Fallback: the count TRAILS the noun — "replace windows 2", "windows: 2",
    // "windows x2". Real phrasing from a live search ("Replace windows 2,
    // sliding, 72x80") priced as one window because the matcher only ever
    // looked for a number *before* the noun (caught 2026-07-16). The same
    // dimension/measurement guards apply, so "window 72x80" is still a size,
    // not 72 windows.
    const trailing = count ? null : normalized.match(COUNT_AFTER_NOUN);
    const matched = count ?? trailing;
    if (matched) {
      let value = Number(matched[1]);
      if (value > 0) {
        // Pair-priced items counted in single doors: "2 french doors" is
        // one pair, not two.
        if (entry.unit === "pair") value = Math.ceil(value / 2);
        return { quantity: value, isDefaulted: false };
      }
    }
    return { quantity: entry.defaultQuantity, isDefaulted: true };
  }
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
  /** EPCI's central estimate × quantity — a real data point, displayed as
   *  "typically ~$X" to anchor wide low–high bands (e.g. hardwood's 4×
   *  spread, which is material-grade variance, not estimation noise). */
  all_in_typical: number;
}

/** Scope add-ons: real catalog items composed on top of the base job when
 *  the description says the work includes them — the clarify chat asks
 *  ("does the old floor need to come out?") and writes these phrases into
 *  its canonical details. Same-trade items only, so they price from the
 *  same EPCI response as the base job. */
export const SCOPE_ADD_ONS: Array<{
  categories: string[];
  keywords: string[];
  itemId: string;
  label: string;
  /** When set, the add-on fires ONLY for these job_types, not the whole
   *  category. A removal add-on for a light fixture must not attach to "replace
   *  outlet" — the word "replace" is shared, the job is not. Category-only
   *  gating can't express that; this can. */
  jobTypes?: string[];
  /** True when the add-on is a FIXED cost for the job rather than a per-unit
   *  rate — add it once, after the quantity multiply.
   *
   *  Add-ons are otherwise folded into the per-unit rate and scaled with the
   *  base job, which is right for every per-sq-ft add-on here (removing 300 sq
   *  ft of old floor costs 300× removing one). Containment is not that: the
   *  barriers, the negative-air machine and the filters are bought once for the
   *  job. Billed per unit it produced $31,427 for 40 sq ft of mold and $115,039
   *  for 150 — MORE for a smaller job than the 100 sq ft reference, which is
   *  how it was caught (2026-07-22). */
  flat?: boolean;
}> = [
  { categories: ["Flooring"], keywords: ["remov", "tear out", "tear-out", "rip out", "demo"], itemId: "flooring-removal-only", label: "old floor removal" },
  { categories: ["Flooring"], keywords: ["subfloor"], itemId: "subfloor-repair", label: "subfloor repair" },
  { categories: ["Flooring"], keywords: ["leveling", "self-level", "level the"], itemId: "floor-leveling", label: "floor leveling" },
  // TV mounting's two real cost drivers — without these a fireplace mount with
  // hidden cords prices the same as a bracket screwed into drywall.
  { categories: ["Electrical"], keywords: ["conceal", "hide the cord", "hide cord", "hide wire", "hide the wire", "in-wall", "in wall", "wires hidden", "hidden wire", "hide cable"], itemId: "tv-cord-concealment", label: "cord concealment" },
  { categories: ["Electrical"], keywords: ["fireplace", "brick", "stone", "masonry", "concrete"], itemId: "tv-mount-masonry", label: "masonry mounting" },
  // Taking the old fixture down is real labor a bare "install" misses. Gated to
  // the lighting jobs so "replace outlet" can't pull it (2026-07-23).
  { categories: ["Electrical"], jobTypes: ["electrical.lighting", "electrical.ceiling_fan"], keywords: ["remov", "replac", "swap", "take down", "take out", "old fixture", "old light", "light bar", "existing fixture", "existing light", "get rid of", "rip out", "tear out"], itemId: "fixture-removal", label: "old fixture removal" },
  // The biggest fork in a remediation quote: a wipe-down versus a sealed,
  // negative-air containment. Flat — see `flat` above.
  { categories: ["Mold & Pest Control"], keywords: ["containment", "negative air", "seal off", "sealed off", "hepa", "spore", "cross-contamination", "black mold", "toxic"], itemId: "mold-containment", label: "full containment", flat: true },
  // A dishwasher going where one has never been needs a supply line, a drain
  // tee and a circuit — roughly the labor of the install again. Without this,
  // a first-time install quotes the same as swapping one out.
  { categories: ["Appliances"], keywords: ["never had", "no dishwasher", "new spot", "new location", "no hookup", "no existing", "first dishwasher", "where there isn't", "where there is no", "run a line", "new supply line"], itemId: "dishwasher-new-hookup", label: "new hookup (supply, drain, circuit)" },
];

export function detectScopeAddOns(
  entry: JobTypeEntry,
  description: string,
): Array<{ itemId: string; label: string; flat: boolean }> {
  const text = description.toLowerCase();
  return SCOPE_ADD_ONS
    .filter((a) => a.categories.includes(entry.category))
    .filter((a) => !a.jobTypes || a.jobTypes.includes(entry.job_type))
    // Never add an item to itself: subfloor-repair and floor-leveling are both
    // SCOPE_ADD_ONS (riding a flooring install) AND standalone jobs. When the
    // standalone job IS that item, the add-on must not fire, or it double-counts
    // (2026-07-23).
    .filter((a) => a.itemId !== entry.itemId)
    .filter((a) => a.keywords.some((k) => text.includes(k)))
    .map((a) => ({ itemId: a.itemId, label: a.label, flat: a.flat === true }));
}

export function calculateEPCIRange(
  items: EPCIItem[],
  entry: JobTypeEntry,
  quantity: number,
  addOnItemIds: string[] = [],
  /** Add-ons that are a fixed cost for the job, not a per-unit rate — added
   *  once alongside setup rather than scaled (see SCOPE_ADD_ONS.flat). */
  flatAddOnItemIds: string[] = [],
): EPCIComputedRange | null {
  const item = items.find((i) => i.id === entry.itemId);
  if (!item) return null;
  // Older cache rows may predate `typical` — fall back to the band midpoint.
  const typicalOf = (i: EPCIItem) => i.typical ?? (i.low + i.high) / 2;
  let low = item.low;
  let high = item.high;
  let typical = typicalOf(item);
  for (const id of addOnItemIds) {
    const addOn = items.find((i) => i.id === id);
    if (!addOn) continue; // not in this trade's catalog — skip, never guess
    low += addOn.low;
    high += addOn.high;
    typical += typicalOf(addOn);
  }
  let flatLow = 0, flatHigh = 0, flatTypical = 0;
  for (const id of flatAddOnItemIds) {
    const addOn = items.find((i) => i.id === id);
    if (!addOn) continue;
    // A flat add-on's own setup belongs in the flat total too.
    flatLow += addOn.low + (addOn.setupLow ?? 0);
    flatHigh += addOn.high + (addOn.setupHigh ?? 0);
    flatTypical += typicalOf(addOn) + (addOn.setupTypical ?? 0);
  }
  // Setup is added ONCE, outside the multiply — that is the whole point of
  // splitting it out of the per-unit rate.
  return {
    all_in_low: low * quantity + (item.setupLow ?? 0) + flatLow,
    all_in_high: high * quantity + (item.setupHigh ?? 0) + flatHigh,
    all_in_typical: typical * quantity + (item.setupTypical ?? 0) + flatTypical,
  };
}

export function rangesOverlap(aLow: number, aHigh: number, bLow: number, bHigh: number): boolean {
  return aLow <= bHigh && bLow <= aHigh;
}

// --- Cross-trade job composition -------------------------------------------
//
// Some flagship EPCI items are deliberately scoped to one part of a job —
// check each item's own `description` on estimationpro.ai/api/v1/costs.
// `bathroom-vanity-installation` (cabinetry trade) is labor-only ("includes
// setting vanity, attaching hardware; countertop and plumbing separate"),
// verified live 2026-07-06: a lone vanity estimate showed $236-708 when a
// real vanity swap (cabinet + top + faucet) runs closer to $2,000+. Unlike
// SCOPE_ADD_ONS (same-trade, keyword-triggered extras), these are companion
// items from OTHER trades that make the job complete — included by default,
// removable only when the description says the customer is supplying or
// keeping that part themselves.
export interface JobComponent {
  trade: string;
  itemId: string;
  label: string;
  /** Multiplier for the base job's resolved quantity — e.g. 1 for "one
   *  faucet per vanity", or a sq-ft conversion parsed from the description
   *  for a countertop sized off vanity width. */
  quantityOf: (baseQuantity: number, description: string) => number;
  /** Phrases that suppress this normally-included component — e.g. "keep
   *  existing faucet" drops the faucet line from a vanity swap. */
  excludeKeywords: string[];
}

export const JOB_COMPONENTS: Record<string, JobComponent[]> = {
  "carpentry.vanity": [
    {
      trade: "countertops",
      itemId: "laminate-countertop-installed",
      label: "vanity top",
      // Standard 22in-deep vanity top; width parsed from the description
      // (the clarify chat asks for it) when present, else the common 36in.
      quantityOf: (qty, description) => {
        const m = description.match(/(\d{2,3})\s*(?:in\b|inch|")/i);
        const widthIn = m ? Number(m[1]) : 36;
        return qty * (widthIn * 22) / 144;
      },
      excludeKeywords: ["no countertop", "no top", "cabinet only", "top separate", "existing top", "keep the top", "keep existing top"],
    },
    {
      trade: "plumbing",
      itemId: "faucet-install-plumbing",
      label: "faucet install",
      quantityOf: (qty) => qty,
      excludeKeywords: ["keep existing faucet", "existing faucet", "no faucet", "faucet separate"],
    },
  ],
};

export function resolveJobComponents(jobType: string, description: string): JobComponent[] {
  const components = JOB_COMPONENTS[jobType];
  if (!components) return [];
  const text = description.toLowerCase();
  return components.filter((c) => !c.excludeKeywords.some((k) => text.includes(k)));
}

/** Sums the base item (plus any same-trade SCOPE_ADD_ONS) with cross-trade
 *  JOB_COMPONENTS into one range. `itemsByTrade` must carry an entry for
 *  every trade the base job and its components reference; a component whose
 *  trade wasn't fetched or doesn't carry that item id is skipped — never
 *  guessed, same policy as calculateEPCIRange's add-on lookup. */
export function calculateComposedRange(
  itemsByTrade: Record<string, EPCIItem[]>,
  entry: JobTypeEntry,
  quantity: number,
  description: string,
  addOnItemIds: string[] = [],
  flatAddOnItemIds: string[] = [],
): (EPCIComputedRange & { includedLabels: string[] }) | null {
  const base = calculateEPCIRange(
    itemsByTrade[entry.trade] ?? [],
    entry,
    quantity,
    addOnItemIds,
    flatAddOnItemIds,
  );
  if (!base) return null;

  let { all_in_low, all_in_high, all_in_typical } = base;
  const includedLabels: string[] = [];
  const typicalOf = (i: EPCIItem) => i.typical ?? (i.low + i.high) / 2;

  for (const component of resolveJobComponents(entry.job_type, description)) {
    const item = itemsByTrade[component.trade]?.find((i) => i.id === component.itemId);
    if (!item) continue;
    const q = component.quantityOf(quantity, description);
    all_in_low += item.low * q;
    all_in_high += item.high * q;
    all_in_typical += typicalOf(item) * q;
    includedLabels.push(component.label);
  }

  return { all_in_low, all_in_high, all_in_typical, includedLabels };
}
