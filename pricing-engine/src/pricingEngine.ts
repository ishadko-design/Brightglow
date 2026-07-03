// Local All-In Cost Range engine.
//
// Blends SF DBI building permit valuations (data.sfgov.org) with retail
// material pricing to produce a defensible cost range for a home-services
// job, instead of a made-up "$100-250" placeholder.

const SF_PERMITS_ENDPOINT = "https://data.sfgov.org/resource/i98e-djp9.json";
const CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24h
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

export interface InsufficientDataResult {
  error: string;
  fallback: string;
}

// --- job_type -> SF permit description keywords -----------------------

const JOB_TYPE_KEYWORDS: Record<string, string[]> = {
  "bathroom.vanity": ["vanity", "bathroom sink"],
  "bathroom.full": ["bathroom remodel", "bathroom renovation"],
  "kitchen.remodel": ["kitchen remodel", "kitchen renovation"],
};

// --- keyword rules for normalizing a free-text permit description -----

const NORMALIZE_RULES: Array<{ job_type: string; keywords: string[] }> = [
  { job_type: "bathroom.vanity", keywords: ["vanity"] },
  { job_type: "bathroom.full", keywords: ["bathroom remodel", "bathroom renovation", "full bath"] },
  { job_type: "kitchen.remodel", keywords: ["kitchen remodel", "kitchen renovation"] },
];

// Materials required to price a given job_type, matched against
// Material.name by substring. All categories must have at least one match
// for calculateMaterialFloor to return a number.
const REQUIRED_MATERIAL_CATEGORIES: Record<string, string[]> = {
  "bathroom.vanity": ["vanity", "top", "faucet", "mirror"],
};

// --- permit cache (24h) -------------------------------------------------

interface CacheEntry {
  fetchedAt: number;
  data: Permit[];
}

const permitCache = new Map<string, CacheEntry>();

function cacheKey(jobKeywords: string[], months: number): string {
  return `${months}:${[...jobKeywords].sort().join("|").toLowerCase()}`;
}

/** Test/ops hook — clears the in-memory permit cache. */
export function clearPermitCache(): void {
  permitCache.clear();
}

// --- 1. fetchSFPermits --------------------------------------------------

export async function fetchSFPermits(jobKeywords: string[], months: number): Promise<Permit[]> {
  const key = cacheKey(jobKeywords, months);
  const cached = permitCache.get(key);
  if (cached && Date.now() - cached.fetchedAt < CACHE_TTL_MS) {
    return cached.data;
  }

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

  const url = `${SF_PERMITS_ENDPOINT}?$where=${encodeURIComponent(where)}&$limit=5000`;

  try {
    const headers: Record<string, string> = {};
    if (process.env.SF_OPEN_DATA_APP_TOKEN) {
      headers["X-App-Token"] = process.env.SF_OPEN_DATA_APP_TOKEN;
    }
    const res = await fetch(url, { headers });
    if (!res.ok) {
      throw new Error(`SF permits API returned ${res.status}`);
    }
    const rows = (await res.json()) as any[];

    const permits: Permit[] = rows
      .map((row) => ({
        contractor: row.contractor_name ?? null,
        description: row.description ?? "",
        estimated_cost: Number(row.estimated_cost ?? 0),
        filed_date: row.filed_date ?? "",
        completed_date: row.completed_date ?? null,
        status: row.status ?? "",
      }))
      .filter((p) => p.status.toLowerCase() !== "withdrawn");

    permitCache.set(key, { fetchedAt: Date.now(), data: permits });
    return permits;
  } catch (err) {
    console.error("fetchSFPermits: failed to fetch SF permit data", err);
    // Serve stale cache over a hard failure if we have anything at all.
    return cached?.data ?? [];
  }
}

// --- 2. normalizeScope ---------------------------------------------------

export function normalizeScope(description: string): { job_type: string; size: number | null } | null {
  const text = description.toLowerCase();

  const sizeMatch = text.match(/(\d+)\s*(?:in\b|inch|")/);
  const size = sizeMatch ? Number(sizeMatch[1]) : null;

  for (const rule of NORMALIZE_RULES) {
    if (rule.keywords.some((kw) => text.includes(kw))) {
      return { job_type: rule.job_type, size };
    }
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

// --- 3. calculatePermitRange ---------------------------------------------

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 1) return sorted[0];
  const idx = (p / 100) * (sorted.length - 1);
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  const frac = idx - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

export function calculatePermitRange(permits: Permit[], scope: JobScope): PermitRange | null {
  const normalized = normalizePermits(permits);

  const matched = normalized.filter((p) => {
    if (p.job_type !== scope.job_type) return false;
    if (p.size === null) return true;
    return Math.abs(p.size - scope.width_in) <= 6;
  });

  if (matched.length < 10) return null;

  const costs = matched.map((p) => p.estimated_cost).filter((c) => c > 0).sort((a, b) => a - b);
  if (costs.length < 10) return null;

  return {
    p25: percentile(costs, 25),
    p50: percentile(costs, 50),
    p75: percentile(costs, 75),
    count: costs.length,
  };
}

// --- 4. calculateMaterialFloor --------------------------------------------

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

// --- 5. getLocalRange -------------------------------------------------

export async function getLocalRange(
  job_type: string,
  scope: JobScope,
  materials: Material[],
): Promise<LocalRange | InsufficientDataResult> {
  const keywords = JOB_TYPE_KEYWORDS[job_type] ?? [job_type];
  const permits = await fetchSFPermits(keywords, 6);
  const permitRange = calculatePermitRange(permits, scope);

  if (!permitRange) {
    return { error: "Insufficient data", fallback: "Get 3 bids" };
  }

  const materialFloor = calculateMaterialFloor(materials, scope);
  if (materialFloor === null) {
    return { error: "Insufficient data", fallback: "Get 3 bids" };
  }

  // valuations are lowballed
  const p25 = permitRange.p25 * PERMIT_VALUATION_BUFFER;
  const p75 = permitRange.p75 * PERMIT_VALUATION_BUFFER;

  const material_low = materialFloor * 0.9;
  const material_high = materialFloor * 1.3;

  const labor_low = Math.max(p25 - materialFloor, SF_LABOR_FLOOR);
  const labor_high = p75 - materialFloor;

  return {
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

// --- 6. formatDisplayText -------------------------------------------------

function money(n: number): string {
  return `$${Math.round(n).toLocaleString("en-US")}`;
}

export function formatDisplayText(range: LocalRange | InsufficientDataResult): string {
  if ("error" in range) {
    return `${range.error}. ${range.fallback}.`;
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
