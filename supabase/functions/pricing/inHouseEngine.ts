// In-house price computation — the default data source when EPCI is off
// (licensing unresolved). Produces the same EPCIItem[] shape fetchEPCIRaw
// returns, so classification, quantity resolution, scope add-ons, and
// cross-trade composition downstream are source-agnostic.
//
//   low     = laborHours.low     × state p25 wage    × burden + materials.low     × matFactor
//   typical = laborHours.typical × state median wage × burden + materials.typical × matFactor
//   high    = laborHours.high    × state p75 wage    × burden + materials.high    × matFactor
//
// Pure and synchronous — wages ship in the bundle (wageTable.generated.ts),
// so unlike the EPCI path there is no fetch and no cache table involved.

import {
  burdenFor,
  CATALOG_BY_ID,
  COST_CATALOG,
  type CostCatalogEntry,
} from "./costCatalog.ts";
import { NATIONAL_WAGES, STATE_WAGES, type WageRow } from "./wageTable.generated.ts";
import { METRO_WAGES, ZIP3_CBSA } from "./metroWages.generated.ts";
import { stateForZip } from "./zipState.ts";
import type { EPCIComputedRange, EPCIItem } from "./pricingEngine.ts";

/** The OEWS metro (CBSA) a zip falls in, or null when it's rural/micropolitan
 *  (no metro wage data) — those price on state wages. zip3 granularity: wages
 *  don't vary meaningfully within a 3-digit prefix inside one metro. */
export function metroForZip(zip: string | undefined): string | null {
  if (!zip) return null;
  const m = zip.trim().match(/^(\d{3})/);
  return m ? (ZIP3_CBSA[m[1]] ?? null) : null;
}

/** Share of the local labor-cost deviation that passes through to material
 *  prices. Commodity materials move on national supply chains, but delivery,
 *  local markup, and shop overhead track the local cost level — published
 *  city cost indexes (RSMeans-style) show materials varying roughly a
 *  quarter as much as labor between cheap and expensive markets. */
const MATERIALS_PASSTHROUGH = 0.25;

/** No contractor rolls a truck below these — floors the *job total* (after
 *  quantity), applied in applyServiceMinimum by the caller, not per unit.
 *  Values are conservative national service-call minimums per trade. */
const SERVICE_MINIMUMS: Record<string, number> = {
  plumbing: 150,
  electrical: 150,
  hvac: 150,
  paint: 200,
  deck: 200,
  cabinetry: 150,
  framing: 200,
  roofing: 250,
  flooring: 200,
  windows: 150,
  doors: 150,
  landscaping: 100,
  countertops: 150,
  // Truck-roll trades added 2026-07-22. Appliance and pest both sell a minimum
  // visit the market actually posts (a diagnostic call, an initial treatment);
  // remediation sits higher because the crew arrives with equipment.
  appliance: 90,
  remediation: 250,
  pest: 125,
  // Auto: the customer drives to the shop, so there's no truck roll to cover —
  // minimums are a shop-supplies/bay-time floor and sit well below the trades'.
  // Tires and detailing genuinely sell $20–30 tickets (a flat repair, a wash),
  // so their floors have to stay low or the engine invents a minimum that the
  // market doesn't charge.
  "auto-repair": 90,
  "auto-tires": 20,
  "auto-detailing": 15,
  "auto-body": 120,
  "auto-glass": 60,
};

/** Wage for a SOC at the finest geography we have data for: metro first, then
 *  state, then national. `regional` is false only at the national fallback. */
function wageFor(
  cbsa: string | null,
  state: string | null,
  soc: string,
): { wage: WageRow; regional: boolean } {
  const metroRow = cbsa ? METRO_WAGES[cbsa]?.[soc] : undefined;
  if (metroRow) return { wage: metroRow, regional: true };
  const stateRow = state ? STATE_WAGES[state]?.[soc] : undefined;
  if (stateRow) return { wage: stateRow, regional: true };
  return { wage: NATIONAL_WAGES[soc], regional: false };
}

/** Local cost level relative to national, derived from the wage table itself
 *  (mean of local-median / national-median across the SOCs the area reports)
 *  at the finest geography available — no hand-maintained index to go stale.
 *  Clamped: OEWS suppression in a thin area must not produce a wild factor. */
export function areaCostFactor(cbsa: string | null, state: string | null): number {
  const table = (cbsa && METRO_WAGES[cbsa]) || (state ? STATE_WAGES[state] : undefined);
  if (!table) return 1;
  const ratios: number[] = [];
  for (const [soc, row] of Object.entries(table)) {
    const national = NATIONAL_WAGES[soc];
    if (national) ratios.push(row.median / national.median);
  }
  if (ratios.length === 0) return 1;
  const mean = ratios.reduce((a, b) => a + b, 0) / ratios.length;
  return Math.min(1.4, Math.max(0.8, mean));
}

/** Back-compat state-only cost factor (metro-unaware) — kept for tests/callers
 *  that reason about a whole state. */
export function stateCostFactor(state: string | null): number {
  return areaCostFactor(null, state);
}

/** Face area (sq ft) that each size-sensitive item's catalog price assumes.
 *  Unit-priced ("each") openings vary enormously in size — a 72x80 slider is
 *  4x the glass of a standard 30x48 replacement window — and before this the
 *  engine priced them identically (a live SF search for "windows 2, sliding,
 *  72x80" estimated ~$1.5k against real quotes of $4-6k, 2026-07-16). Only
 *  items whose cost genuinely tracks the unit's size are listed; anything
 *  absent ignores stated dimensions. */
const REFERENCE_AREA_SQFT: Record<string, number> = {
  "vinyl-window-replacement": 10, // ~30x48in, a standard replacement window
  "casement-window-replacement": 8, // ~24x48in
  "bay-bow-window-replacement": 25,
  "egress-window-installation": 15,
  "sliding-patio-door": 40, // ~72x80in
  "french-door-installation": 40, // ~72x80in, as a pair
  "exterior-door-steel": 21, // 36x84in
  "interior-door-hollow-core": 18, // 30x84in
  "garage-door-single": 63, // 9x7ft
};

/** Face area in sq ft from dimensions the user stated — "72x80" (inches by
 *  convention), "6ft x 6ft", "72 x 80 in". Null when the text states no size,
 *  which leaves the catalog's reference size in force. */
export function parseFaceAreaSqFt(description: string): number | null {
  const t = description.toLowerCase();
  const ft = t.match(/(\d{1,2})\s*(?:ft|foot|feet|')\s*[x×]\s*(\d{1,2})\s*(?:ft|foot|feet|')?/);
  if (ft) {
    const [a, b] = [Number(ft[1]), Number(ft[2])];
    if (a >= 1 && a <= 20 && b >= 1 && b <= 20) return a * b;
  }
  const inch = t.match(/(\d{2,3})\s*(?:in|inch|inches|")?\s*[x×]\s*(\d{2,3})\s*(?:in|inch|inches|")?/);
  if (inch) {
    const [a, b] = [Number(inch[1]), Number(inch[2])];
    if (a >= 12 && a <= 240 && b >= 12 && b <= 240) return (a * b) / 144;
  }
  return null;
}

export interface SizeScale {
  itemId: string;
  materials: number;
  labor: number;
}

/** Multipliers for a stated size vs. the item's reference size. Both scale
 *  SUBLINEARLY — a window with 4x the area is nowhere near 4x the price: glass
 *  and frame get cheaper per sq ft as units grow, and an install carries fixed
 *  setup either way. Exponents are fitted to a live SF quote (2x 72x80 vinyl
 *  sliders: unit $750 each, installed $2-3k each): area ratio 4 → materials
 *  x1.74 ($450 → $783, vs the $750 actual). Clamped so a mis-parsed dimension
 *  can never produce a wild number. */
export function sizeScale(itemId: string, description: string): SizeScale | null {
  const reference = REFERENCE_AREA_SQFT[itemId];
  if (!reference) return null;
  const area = parseFaceAreaSqFt(description);
  if (!area) return null;
  const ratio = Math.min(5, Math.max(0.4, area / reference));
  if (Math.abs(ratio - 1) < 0.05) return null; // already the reference size
  return { itemId, materials: Math.pow(ratio, 0.4), labor: Math.pow(ratio, 0.5) };
}

/** Openings priced "each" carry a catalog band for a full-unit *insert*
 *  replacement. But the same job word covers three very different scopes, and
 *  before this the engine collapsed them onto that one band — a live "Replace
 *  window" search read ~$770 whether the user meant a foggy pane or a full
 *  tear-out (2026-07-18). These items are the ones where the scope word is the
 *  dominant cost driver, so a multiplier off the insert reference is honest. */
const SCOPE_SCALABLE = new Set([
  "vinyl-window-replacement",
  "casement-window-replacement",
  "bay-bow-window-replacement",
  "egress-window-installation",
  "sliding-patio-door",
  "french-door-installation",
]);

export interface ScopeScale {
  materials: number;
  labor: number;
  /** Canonical label surfaced to the user, e.g. "glass only". */
  scope: "glass only" | "full-frame replacement" | "new install" | "full-size vehicle" | "SUV/truck" | "compact car";
}

/** Which replacement scope the words assert, as multipliers off the item's
 *  *insert* catalog band (the unmarked default = 1x, returns null):
 *   - glass only (reglaze / failed IGU / broken pane): the unit and frame
 *     stay; you buy glass and an hour of labor. ~0.4-0.5x.
 *   - full-frame / new-construction (tear out to the rough opening, new nail-
 *     fin unit, re-trim, sometimes wall work): materials and hours both climb.
 *     Calibrated so a full-frame slider lands in the $5-6k a real construction
 *     quote showed (2026-07-18), on top of the door's larger base band.
 *  Sublinear like sizeScale, and only for items where scope is the big lever. */
export function windowScopeScale(itemId: string, description: string): ScopeScale | null {
  if (!SCOPE_SCALABLE.has(itemId)) return null;
  const t = ` ${description.toLowerCase()} `;
  const glassOnly =
    /\b(glass[- ]only|glass replacement|replace the glass|just the glass|only the glass|re-?glaze|re-?glazing|reglaze|sash[- ]only|broken pane|cracked pane|broken glass|foggy (glass|pane|window)|failed seal|fogged|insulated glass unit|\bigu\b)\b/;
  const fullFrame =
    /\b(full[- ]frame|full frame|new[- ]construction|frame replacement|replace the frame|whole window|entire window|full replacement|tear[- ]out|nail[- ]fin|rough opening|structural)\b/;
  if (glassOnly.test(t)) return { materials: 0.5, labor: 0.55, scope: "glass only" };
  if (fullFrame.test(t)) return { materials: 1.9, labor: 1.7, scope: "full-frame replacement" };
  return null;
}

/** Recessed lighting is priced as a RETROFIT — a can into an existing ceiling
 *  with power nearby — because that is what most requests mean and what the
 *  consumer aggregators publish ($125-330/light). A from-scratch install runs
 *  ~2.5x that (Homewyse $380-529) for the new circuit, wire fishing, and
 *  cutting and patching the ceiling. The engine cannot tell them apart from
 *  "install recessed lighting" alone, so the clarify chat asks and writes the
 *  answer into the description; this reads it. Absent signal → retrofit, the
 *  common case. New-install cost is mostly labor, hence the split factors.
 *  NB: the signals deliberately avoid "new circuit" — that phrase is a keyword
 *  of the dedicated-circuit job and would steal the routing. The clarify chat
 *  is told to write "no existing light there" instead. */
export function recessedInstallScale(itemId: string, description: string): ScopeScale | null {
  if (itemId !== "recessed-light-install") return null;
  const t = ` ${description.toLowerCase()} `;
  const newInstall =
    /\b(no light there|no existing (light|fixture)|no existing|from scratch|brand[- ]new spot|add lights|adding lights|never had a light|no power there)\b/;
  if (newInstall.test(t)) return { materials: 1.5, labor: 2.6, scope: "new install" };
  return null;
}

/** Auto jobs whose cost scales with the VEHICLE'S SIZE — wrap film and detail
 *  hours and respray area all grow with the body. A bumper, a windshield or an
 *  alternator does not, so those are deliberately excluded: an F-250's
 *  alternator is the same part as a Miata's. */
const VEHICLE_SIZE_SENSITIVE = new Set([
  "vehicle-wrap-full",
  "vehicle-wrap-partial",
  "vehicle-wrap-removal",
  "full-detail",
  "interior-detail",
  "exterior-detail-wax",
  "ceramic-coating",
  "paint-correction",
  "full-respray",
  "panel-respray",
]);

/** Coarse vehicle-size multiplier. An F-250 and a Miata used to price the same
 *  wrap; this reads the size the clarify chat pins down ("SUV", "full-size
 *  truck") and scales the size-sensitive auto items. Deliberately COARSE —
 *  four tiers, not per-model — because the app has no vehicle database, and a
 *  tier captures most of the spread honestly where a made-up exact figure
 *  would not. Both sides scale: more body is more film AND more hours. Default
 *  (no size stated) is 1.0, the mid-size the catalog bands already assume. */
export function vehicleSizeScale(itemId: string, description: string): ScopeScale | null {
  if (!VEHICLE_SIZE_SENSITIVE.has(itemId)) return null;
  const t = ` ${description.toLowerCase()} `;
  // Order matters: check the big tier before the plain "truck"/"suv" tier.
  if (/\b(full[- ]size|full size|dually|lifted|3500|2500|f-?250|f-?350|sprinter|box truck|cargo van|suburban|expedition|tahoe)\b/.test(t)) {
    return { materials: 1.55, labor: 1.55, scope: "full-size vehicle" };
  }
  if (/\b(suv|truck|pickup|van|minivan|jeep|crossover|4runner|tacoma|silverado|f-?150|ram)\b/.test(t)) {
    return { materials: 1.3, labor: 1.3, scope: "SUV/truck" };
  }
  if (/\b(compact|subcompact|sedan|coupe|hatchback|small car|two[- ]door|2[- ]door|miata|civic|corolla|smart car)\b/.test(t)) {
    return { materials: 0.85, labor: 0.85, scope: "compact car" };
  }
  return null;
}

/** Fold a stated size and a stated scope into the single SizeScale the item
 *  computation consumes — both are plain multipliers on materials and labor,
 *  so they compose. Null when neither was stated (the catalog band stands). */
export function combineSizeScope(
  itemId: string,
  size: SizeScale | null,
  ...scopes: (ScopeScale | null)[]
): SizeScale | null {
  const present = scopes.filter((s): s is ScopeScale => s != null);
  if (!size && present.length === 0) return null;
  return {
    itemId,
    materials: (size?.materials ?? 1) * present.reduce((m, s) => m * s.materials, 1),
    labor: (size?.labor ?? 1) * present.reduce((l, s) => l * s.labor, 1),
  };
}

/** A grade signal the user's words assert about the materials/fixtures —
 *  "high-end faucet", "builder-grade cabinets". Scales the MATERIALS side of
 *  every item (labor is unchanged: a premium fixture isn't more hours to fit).
 *  Bounded and modest — it nudges within the realistic band, on top of the
 *  material-specific job types the taxonomy already distinguishes (hardwood
 *  vs laminate); it never invents a figure. `tier` is surfaced in the label. */
export function qualityTier(description: string): { factor: number; tier: "premium" | "budget" | null } {
  const t = ` ${description.toLowerCase()} `;
  const has = (words: string[]) => words.some((w) => t.includes(w));
  const premium = [
    "high-end", "high end", "luxury", "luxurious", "premium", "top-of-the-line",
    "top of the line", "custom", "designer", "upscale", "high-grade", "top-tier",
  ];
  const budget = [
    "builder-grade", "builder grade", "basic", "economy", "budget", "cheapest",
    "cheap", "entry-level", "entry level", "contractor-grade", "low-end", "bare bones",
  ];
  if (has(premium)) return { factor: 1.4, tier: "premium" };
  if (has(budget)) return { factor: 0.75, tier: "budget" };
  return { factor: 1, tier: null };
}

/** After-hours / emergency premium. A burst pipe at 2am or a lockout is billed
 *  1.5-2x the day rate across the trades — it is the single biggest lever on
 *  the price of the jobs that carry it, and was invisible before (2026-07-23).
 *
 *  Applies to the whole range, not just labor: an emergency parts run and the
 *  after-hours supply house both cost more, and the multiplier is how the trade
 *  actually quotes it. Deliberately conservative at 1.6x typical — the true
 *  spread is wide and situational, and the label tells the user it is an
 *  after-hours figure so a daytime call doesn't read as us being high. */
export function emergencyFactor(description: string): { factor: number; emergency: boolean } {
  const t = ` ${description.toLowerCase()} `;
  const signals = [
    "emergency", "urgent", "asap", "right now", "middle of the night",
    "after hours", "after-hours", "2am", "3am", "midnight", "weekend",
    "same day", "same-day", "immediately", "gushing", "spraying everywhere",
    "can't get in", "locked out", "flooded",
  ];
  return signals.some((w) => t.includes(w))
    ? { factor: 1.6, emergency: true }
    : { factor: 1, emergency: false };
}

function computeItem(
  entry: CostCatalogEntry,
  cbsa: string | null,
  state: string | null,
  tierFactor: number,
  size: SizeScale | null,
): EPCIItem {
  const { wage, regional } = wageFor(cbsa, state, entry.soc);
  // Materials absorb the local cost level, the requested grade, and the unit's
  // size; labor takes the local wage and the size (a bigger unit is more
  // hours), never the grade — a premium fixture isn't longer to fit.
  const matFactor = (1 + MATERIALS_PASSTHROUGH * (areaCostFactor(cbsa, state) - 1)) *
    tierFactor * (size?.materials ?? 1);
  const hours = size?.labor ?? 1;
  const rate = (w: number) => w * burdenFor(entry.trade);
  // Cent precision, not whole dollars: per-sq-ft rates get multiplied by
  // quantity downstream, so rounding $1.19/sq ft to $1 is a 16% error
  // across a lawn. Display rounding is the client's job.
  const cents = (n: number) => Math.round(n * 100) / 100;
  // Setup takes the local wage and cost level like everything else, but NOT the
  // size scale — a bigger unit doesn't lengthen the mobilization — and not the
  // grade factor, since demo and disposal cost the same whatever goes back in.
  const setup = entry.setup;
  return {
    id: entry.itemId,
    description: entry.description,
    unit: entry.unit,
    low: cents(entry.laborHours.low * hours * rate(wage.p25) + entry.materials.low * matFactor),
    typical: cents(entry.laborHours.typical * hours * rate(wage.median) + entry.materials.typical * matFactor),
    high: cents(entry.laborHours.high * hours * rate(wage.p75) + entry.materials.high * matFactor),
    regionallyAdjusted: regional,
    ...(setup
      ? {
        setupLow: cents(setup.hours.low * rate(wage.p25) + setup.materials.low * areaCostFactor(cbsa, state)),
        setupTypical: cents(setup.hours.typical * rate(wage.median) + setup.materials.typical * areaCostFactor(cbsa, state)),
        setupHigh: cents(setup.hours.high * rate(wage.p75) + setup.materials.high * areaCostFactor(cbsa, state)),
      }
      : {}),
  };
}

/** Drop-in equivalent of fetchEPCIRaw(trade, zip) — same item ids, same
 *  shape, computed from the bundled catalog + OEWS wages instead of a
 *  network call. Unknown trades return [] (downstream treats that as
 *  "no data", same as an EPCI miss). */
export function computeInHouseItems(
  trade: string,
  zip: string | undefined,
  tierFactor = 1,
  size: SizeScale | null = null,
): EPCIItem[] {
  const cbsa = metroForZip(zip);
  const state = stateForZip(zip);
  return COST_CATALOG.filter((e) => e.trade === trade).map((e) =>
    // Size applies only to the item it was measured for — never to a
    // cross-trade companion that happens to share the request.
    computeItem(e, cbsa, state, tierFactor, size?.itemId === e.itemId ? size : null)
  );
}

/** Floor a composed job total at the trade's service-call minimum. Only for
 *  in-house ranges — EPCI's bands already embed minimum-charge reality. */
/** Items that are a POSTED-PRICE SERVICE rather than a job the shop takes on,
 *  so the trade's service minimum does not apply to them.
 *
 *  A minimum exists because a shop will not occupy a bay, or roll a truck, for
 *  less than some floor. But a smog check IS the product — stations advertise
 *  $50-80 in California and compete on it — so flooring it at the auto-repair
 *  minimum of $90 priced it 64% above the published band (caught by
 *  accuracy.test.ts, 2026-07-23). Add an item here only when the market
 *  genuinely posts a price below the trade's floor. */
const MINIMUM_EXEMPT = new Set(["smog-check"]);

export function applyServiceMinimum<T extends EPCIComputedRange>(
  range: T,
  trade: string,
  itemId?: string,
): T {
  if (itemId && MINIMUM_EXEMPT.has(itemId)) return range;
  const minimum = SERVICE_MINIMUMS[trade];
  if (!minimum) return range;
  const low = Math.max(range.all_in_low, minimum);
  const typical = Math.max(range.all_in_typical, low);
  const high = Math.max(range.all_in_high, typical);
  return { ...range, all_in_low: low, all_in_typical: typical, all_in_high: high };
}

// --- Labor-only estimates (long-tail pilot) --------------------------------
//
// For jobs outside the catalog we know the trade but not the parts. Rather
// than a number we can't stand behind — or nothing at all — show what we CAN
// compute rigorously: local billed labor. Deliberately NOT built from the
// CATEGORY_GENERAL buckets, whose arbitrary defaults (200 sq ft of carpentry)
// caused the $220-vs-$3,476 swing; this is hourly rate x a stated visit
// length, with the hours assumption surfaced to the user.

/** Service calls carry more overhead per billed hour than project work — the
 *  truck roll, scheduling, and drive time load onto a handful of billed hours
 *  instead of amortizing across a week on site. Measured 2026-07-16: at the
 *  2.2 project burden our national plumber billed $77/hr against a $75-200
 *  market posted range, i.e. at the floor. 3.0 puts it mid-market (~$105/hr).
 *  Applies ONLY to labor-only estimates; catalog items keep BURDEN_MULTIPLIER,
 *  which is calibrated against all-in installed anchors. */
export const SERVICE_CALL_BURDEN = 3.0;

/** A typical service visit, in hours. Wide on purpose: for an unmodeled job we
 *  genuinely don't know the duration, and the estimate says so (confidence
 *  stays low and the label names the assumption). */
const VISIT_HOURS = { low: 1, typical: 2.5, high: 5 };

/** The occupation that best represents a trade's labor — the SOC most of that
 *  trade's catalog items are priced against. Derived, not hand-maintained, so
 *  it can't drift from the catalog. */
function representativeSoc(trade: string): string | null {
  const counts = new Map<string, number>();
  for (const e of COST_CATALOG) {
    if (e.trade !== trade) continue;
    counts.set(e.soc, (counts.get(e.soc) ?? 0) + 1);
  }
  let best: string | null = null;
  let bestN = 0;
  for (const [soc, n] of counts) {
    if (n > bestN) [best, bestN] = [soc, n];
  }
  return best;
}

export interface LaborOnlyEstimate {
  low: number;
  typical: number;
  high: number;
  /** Local billed rate behind the figure, so the UI can show its basis. */
  hourlyTypical: number;
  hoursLow: number;
  hoursHigh: number;
}

/** Labor-only estimate for a trade in a place. Null when the trade has no
 *  catalog presence (no SOC to price against) — caller then shows nothing. */
export function laborOnlyEstimate(
  trade: string,
  zip: string | undefined,
): LaborOnlyEstimate | null {
  const soc = representativeSoc(trade);
  if (!soc) return null;
  const cbsa = metroForZip(zip);
  const state = stateForZip(zip);
  const { wage } = wageFor(cbsa, state, soc);
  const cents = (n: number) => Math.round(n * 100) / 100;
  const rate = (w: number) => w * SERVICE_CALL_BURDEN;
  return {
    low: cents(VISIT_HOURS.low * rate(wage.p25)),
    typical: cents(VISIT_HOURS.typical * rate(wage.median)),
    high: cents(VISIT_HOURS.high * rate(wage.p75)),
    hourlyTypical: cents(rate(wage.median)),
    hoursLow: VISIT_HOURS.low,
    hoursHigh: VISIT_HOURS.high,
  };
}

/** Sanity hook for tests/calibration: the catalog entry behind an item id. */
export function catalogEntryFor(itemId: string): CostCatalogEntry | undefined {
  return CATALOG_BY_ID.get(itemId);
}
