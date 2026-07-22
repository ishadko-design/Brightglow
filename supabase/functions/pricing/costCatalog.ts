// In-house cost catalog — the estimating knowledge behind the pricing engine
// when EPCI is unavailable (see wageTable.generated.ts for the labor side).
//
// Each entry prices one taxonomy itemId as labor + materials:
//   labor    = laborHours × state OEWS wage (p25/median/p75) × BURDEN_MULTIPLIER
//   material = national baseline USD per unit, incl. typical contractor markup
// low pairs with p25 wages and low hours; typical with median; high with p75.
//
// laborHours are CREW-hours per unit (a 2-person crew for 3 hours = 6).
// The "sanity:" comment on each entry is the published national installed
// range the numbers were anchored against (Angi/HomeAdvisor-class figures,
// 2026) — calibration against EPCI's free tier happens in the comparison
// script; tune hours/materials there, never by editing the computed output.

export interface Band {
  low: number;
  typical: number;
  high: number;
}

export interface CostCatalogEntry {
  itemId: string; // must match JOB_TYPE_TAXONOMY / SCOPE_ADD_ONS / JOB_COMPONENTS ids
  trade: string; // catalog partition, matches JobTypeEntry.trade
  description: string;
  unit: string; // must match the taxonomy entry's unit
  soc: string; // OEWS occupation whose wage prices the labor (wageTable.generated.ts)
  laborHours: Band;
  materials: Band;
}

/** Wage → billed-rate multiplier: payroll burden (~1.35) × overhead + profit
 *  (~1.6). US median plumber $30.67/hr → ~$67/hr billed, which sits inside
 *  the $65–120 service-plumber reality; the single global value is a
 *  deliberate simplification, revisit only with calibration data. */
export const BURDEN_MULTIPLIER = 2.2;

/** Wage → billed-rate multiplier per trade, where the trade's market bills at a
 *  different multiple of the tech's wage than home construction does. Absent a
 *  row, BURDEN_MULTIPLIER applies.
 *
 *  The auto trades all need their own: a shop's posted "door rate" carries the
 *  lift, the scan tool, the parts counter, and a flat-rate pay system, so it
 *  runs far above a contractor's billed rate. Calibrated 2026-07-20 against
 *  published rate surveys:
 *    - auto-repair 5.5 → national tech median $24.34 × 5.5 = $134/hr, against a
 *      surveyed $132–140 national average; p25/p75 give $103–$186 against a
 *      surveyed $85–$200 state spread. (AAA / Tekmetric / AutoLeap, 2026)
 *    - auto-tires 5.0 — high-volume tire shops post under general mechanical.
 *    - auto-body 3.2 — body labor is insurance-rate-suppressed, $60–100/hr
 *      posted, well below mechanical despite a higher OEWS wage.
 *    - auto-glass 4.0 → ~$92/hr, matching mobile glass install labor.
 *    - auto-detailing 3.5 → ~$60/hr; detailing carries no lift, no diagnostic
 *      equipment, and no parts department, so the overhead load is far lighter.
 *  These are the single biggest lever on auto accuracy — retune them from
 *  calibration.test.ts against published whole-job anchors, never by hand. */
export const TRADE_BURDEN: Record<string, number> = {
  "auto-repair": 5.5,
  "auto-tires": 5.0,
  "auto-body": 3.2,
  "auto-glass": 4.0,
  "auto-detailing": 3.5,
  // Moto shops post $80–140/hr independent (JD Power / dealer surveys 2026);
  // 4.7 × the $23.35 national moto-mechanic median lands at ~$110/hr, with
  // p25/p75 giving $89–$139.
  "moto-repair": 4.7,
  "moto-tires": 4.7,
};

/** The wage→billed-rate multiplier that applies to a trade. */
export function burdenFor(trade: string): number {
  return TRADE_BURDEN[trade] ?? BURDEN_MULTIPLIER;
}

const b = (low: number, typical: number, high: number): Band => ({ low, typical, high });

// SOC shorthand (full titles in wageTable.generated.ts / ingest-oews.py)
const PLUMBER = "47-2152";
const ELECTRICIAN = "47-2111";
const HVAC_TECH = "49-9021";
const PAINTER = "47-2141";
const CARPENTER = "47-2031";
const ROOFER = "47-2181";
const CARPET_INSTALLER = "47-2041";
const FLOOR_LAYER = "47-2042";
const FLOOR_SANDER = "47-2043";
const TILE_SETTER = "47-2044";
const LANDSCAPER = "37-3011";
const MAINTENANCE = "49-9071";
// Auto & moto
const AUTO_TECH = "49-3023";
const BODY_REPAIRER = "49-3021";
const GLASS_INSTALLER = "49-3022";
const VEHICLE_CLEANER = "53-7061";
const MOTO_MECH = "49-3052";

export const COST_CATALOG: CostCatalogEntry[] = [
  // --- plumbing --------------------------------------------------------
  // sanity: tank water heater swap $1,000–2,500 installed
  { itemId: "water-heater-install", trade: "plumbing", description: "40–50 gal tank water heater, replace in place", unit: "project", soc: PLUMBER, laborHours: b(3, 4.5, 6.5), materials: b(1000, 1450, 2100) },
  // sanity: tankless conversion $2,500–4,500 (gas line + venting drive the spread)
  // Materials carry the unit ($1,000–1,500) plus gas-line upsizing, venting,
  // and condensate — raised so the typical clears the $2,500 floor (was
  // pricing $2,410, flagged by calibration.test.ts 2026-07-16).
  { itemId: "tankless-water-heater-install", trade: "plumbing", description: "Tankless water heater, incl. venting/gas-line work", unit: "project", soc: PLUMBER, laborHours: b(8, 12, 20), materials: b(1300, 2100, 3400) },
  // sanity: faucet/toilet swap $150–600 installed
  { itemId: "fixture-install", trade: "plumbing", description: "Replace one plumbing fixture (faucet, toilet, sink)", unit: "each", soc: PLUMBER, laborHours: b(1, 2, 3), materials: b(120, 250, 600) },
  // sanity: leak/clog service call $150–700
  { itemId: "pipe-repair", trade: "plumbing", description: "Localized pipe/drain repair or clog clearing", unit: "project", soc: PLUMBER, laborHours: b(1.5, 3, 6), materials: b(30, 80, 250) },
  // sanity: whole-house PEX repipe $4,000–15,000 for ~1,500 sq ft
  { itemId: "whole-house-repipe-pex", trade: "plumbing", description: "Whole-house PEX repipe", unit: "sq ft", soc: PLUMBER, laborHours: b(0.03, 0.05, 0.08), materials: b(0.8, 1.5, 2.5) },
  // sanity: sewer line replacement $50–250 per linear foot (open trench)
  { itemId: "sewer-line-replacement", trade: "plumbing", description: "Sewer lateral replacement, open trench", unit: "linear foot", soc: PLUMBER, laborHours: b(0.5, 0.8, 1.2), materials: b(15, 30, 60) },
  // category-general fallback: one plumber, small parts allowance
  { itemId: "plumber-hourly", trade: "plumbing", description: "General plumbing labor", unit: "hour", soc: PLUMBER, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },
  // vanity JOB_COMPONENT; mid-grade faucet included
  { itemId: "faucet-install-plumbing", trade: "plumbing", description: "Supply and install bathroom faucet", unit: "each", soc: PLUMBER, laborHours: b(1, 1.5, 2.5), materials: b(80, 150, 300) },

  // --- electrical ------------------------------------------------------
  // sanity: 200A panel upgrade $1,800–4,000 (permit/utility coordination in hours)
  { itemId: "panel-upgrade-200amp", trade: "electrical", description: "200-amp service panel upgrade", unit: "project", soc: ELECTRICIAN, laborHours: b(8, 12, 18), materials: b(800, 1300, 2200) },
  // sanity: new/replaced outlet $100–350
  { itemId: "outlet-installation", trade: "electrical", description: "Install or replace an outlet", unit: "each", soc: ELECTRICIAN, laborHours: b(0.75, 1.25, 2.5), materials: b(10, 25, 80) },
  // sanity: ceiling fan install (fan customer-supplied) $150–400
  { itemId: "ceiling-fan-install", trade: "electrical", description: "Install ceiling fan on existing box (fan not included)", unit: "each", soc: ELECTRICIAN, laborHours: b(1.5, 2.5, 4), materials: b(0, 20, 80) },
  // sanity: Level-2 EV charger $1,000–2,500 installed incl. unit
  { itemId: "ev-charger-level2", trade: "electrical", description: "Level-2 EV charger, incl. unit and 240V circuit", unit: "each", soc: ELECTRICIAN, laborHours: b(4, 6, 10), materials: b(450, 900, 1800) },
  // Rooftop solar, priced per panel. Added 2026-07-22: "Install solar panels"
  // had no item, fell through to electrical.general, and showed "~$270 labor
  // only" — a top-of-funnel search this app cannot be silent on.
  //
  // Per-panel is the unit the customer counts in and the unit that scales
  // honestly: residential PV is near-linear in array size once the inverter and
  // permitting are spread across it, so a 6-panel array and a 24-panel array
  // both land near the same $/W. Materials carry the panel, its share of the
  // inverter, racking, balance-of-system, and permitting/interconnection.
  // At a 400W panel this computes to ~$2.30–3.30/W, against a published
  // national $2.50–3.50/W before the federal credit (2026). Quoted GROSS —
  // incentives are a rebate the user claims later, not a lower price, and
  // netting them out would understate every quote the business actually sends.
  // sanity: $850–1,550 per installed panel ($17k–31k for a typical 20-panel,
  // 8 kW system)
  { itemId: "solar-panel-install", trade: "electrical", description: "Rooftop solar PV, per panel, incl. inverter share, racking and permitting", unit: "each", soc: ELECTRICIAN, laborHours: b(1.2, 1.8, 2.6), materials: b(760, 1000, 1350) },
  // sanity: whole-house rewire $4–10 per sq ft
  { itemId: "whole-house-rewire", trade: "electrical", description: "Whole-house rewire", unit: "sq ft", soc: ELECTRICIAN, laborHours: b(0.04, 0.06, 0.09), materials: b(1, 1.8, 3) },
  // sanity: light fixture swap $75–250 (fixture customer-supplied)
  { itemId: "light-fixture-install", trade: "electrical", description: "Install light fixture (fixture not included)", unit: "each", soc: ELECTRICIAN, laborHours: b(0.75, 1.5, 2.5), materials: b(5, 20, 60) },
  { itemId: "electrician-hourly", trade: "electrical", description: "General electrical labor", unit: "hour", soc: ELECTRICIAN, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },
  // TV mounting — an installer/handyman job, not a licensed electrician, so it
  // prices on the general-maintenance wage. Added 2026-07-16: "install tv" had
  // no item at all and fell through to whichever category-general bucket the
  // classifier guessed, swinging $220 (2 electrician hours) to $3,476 (200 sq
  // ft of carpentry) for the same request. Bracket included; the two real cost
  // drivers — concealing the cords and mounting to masonry — are add-ons below.
  // sanity: 55–75in wall mount $200–600 installed
  { itemId: "tv-mount-install", trade: "electrical", description: "TV wall mount, incl. bracket", unit: "each", soc: MAINTENANCE, laborHours: b(1.5, 2.5, 4.5), materials: b(70, 150, 350) },
  // sanity: in-wall cord concealment $100–400 (power + HDMI, patch and paint)
  { itemId: "tv-cord-concealment", trade: "electrical", description: "Conceal TV cords in wall", unit: "each", soc: ELECTRICIAN, laborHours: b(1, 1.5, 3), materials: b(30, 60, 120) },
  // sanity: brick/stone/fireplace surcharge $75–300 over a drywall mount
  { itemId: "tv-mount-masonry", trade: "electrical", description: "Masonry/fireplace mounting surcharge", unit: "each", soc: MAINTENANCE, laborHours: b(0.75, 1.5, 2.5), materials: b(20, 40, 80) },

  // --- hvac ------------------------------------------------------------
  // sanity: gas furnace replacement $3,000–6,500 installed
  { itemId: "gas-furnace-installed", trade: "hvac", description: "Gas furnace replacement, like-for-like", unit: "project", soc: HVAC_TECH, laborHours: b(8, 12, 18), materials: b(2000, 3200, 5500) },
  // sanity: central AC (condenser + coil) $3,800–7,500
  { itemId: "central-ac-installed", trade: "hvac", description: "Central AC condenser + coil, existing ductwork", unit: "project", soc: HVAC_TECH, laborHours: b(11, 15, 21), materials: b(3300, 4800, 7200) },
  // sanity: ducted heat pump $4,500–9,500
  { itemId: "heat-pump-installed", trade: "hvac", description: "Ducted heat pump system", unit: "project", soc: HVAC_TECH, laborHours: b(10, 16, 24), materials: b(2800, 4500, 8000) },
  // sanity: ductless mini-split $2,000–4,000 per zone
  { itemId: "mini-split-per-zone", trade: "hvac", description: "Ductless mini-split, per zone", unit: "each", soc: HVAC_TECH, laborHours: b(4, 7, 10), materials: b(1200, 2000, 3200) },
  // sanity: smart thermostat $200–500 installed incl. unit
  { itemId: "thermostat-installation-smart", trade: "hvac", description: "Smart thermostat, incl. unit", unit: "each", soc: HVAC_TECH, laborHours: b(0.75, 1.25, 2), materials: b(120, 220, 350) },
  // sanity: furnace/AC repair visit $150–800
  { itemId: "furnace-repair", trade: "hvac", description: "HVAC diagnostic + repair", unit: "project", soc: HVAC_TECH, laborHours: b(1, 2.5, 5), materials: b(50, 200, 600) },
  { itemId: "hvac-labor-rate", trade: "hvac", description: "General HVAC labor", unit: "hour", soc: HVAC_TECH, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },

  // --- paint -----------------------------------------------------------
  // Per sq ft of room FLOOR area (matches the taxonomy's 250 sq ft room
  // default): walls + trim, two coats. sanity: $300–800 per average room
  { itemId: "paint-interior-labor", trade: "paint", description: "Interior painting, walls + trim, per sq ft of floor area", unit: "sq ft", soc: PAINTER, laborHours: b(0.016, 0.024, 0.035), materials: b(0.25, 0.45, 0.8) },
  // Per sq ft of paintable siding. sanity: 1,500 sq ft house $2,000–5,000
  { itemId: "paint-exterior-labor", trade: "paint", description: "Exterior painting, per sq ft of siding", unit: "sq ft", soc: PAINTER, laborHours: b(0.015, 0.025, 0.04), materials: b(0.4, 0.7, 1.2) },
  // sanity: kitchen cabinet spray-refinish $1,500–4,000 (~25 LF)
  { itemId: "cabinet-painting-spray", trade: "paint", description: "Cabinet spray painting, per linear foot of cabinetry", unit: "linear foot", soc: PAINTER, laborHours: b(1, 1.5, 2.5), materials: b(8, 15, 25) },

  // --- deck / framing / cabinetry (carpentry trades) ---------------------
  // sanity: pressure-treated deck $25–60 per sq ft built
  { itemId: "pressure-treated-installed", trade: "deck", description: "Pressure-treated deck, framed + decked + rails", unit: "sq ft", soc: CARPENTER, laborHours: b(0.25, 0.35, 0.5), materials: b(8, 14, 22) },
  // Labor + sundries only — top and faucet come in via JOB_COMPONENTS,
  // mirroring the EPCI item this id was scoped to. sanity: $150–500 set-only
  { itemId: "bathroom-vanity-installation", trade: "cabinetry", description: "Set vanity cabinet, attach hardware (top/plumbing separate)", unit: "each", soc: CARPENTER, laborHours: b(2, 3, 5), materials: b(30, 60, 120) },
  // sanity: stock cabinets installed $200–500 per LF
  { itemId: "stock-cabinets-installed", trade: "cabinetry", description: "Stock cabinets, supplied + installed", unit: "linear foot", soc: CARPENTER, laborHours: b(1, 1.5, 2.5), materials: b(80, 150, 300) },
  // sanity: non-bearing interior wall framing $20–60 per LF
  { itemId: "wall-framing", trade: "framing", description: "Wall framing, per linear foot", unit: "linear foot", soc: CARPENTER, laborHours: b(0.35, 0.6, 0.9), materials: b(4, 8, 14) },
  // carpentry.general fallback — intentionally vague, always low confidence
  { itemId: "framing-labor-rate", trade: "framing", description: "General carpentry, per sq ft of project area", unit: "sq ft", soc: CARPENTER, laborHours: b(0.08, 0.15, 0.25), materials: b(1, 3, 8) },

  // --- roofing ---------------------------------------------------------
  // sanity: architectural shingles $4.50–8 per sq ft installed (tear-off incl.)
  { itemId: "architectural-installed", trade: "roofing", description: "Architectural shingles, tear-off + install", unit: "sq ft", soc: ROOFER, laborHours: b(0.025, 0.035, 0.05), materials: b(2, 3, 4.5) },
  // sanity: standing-seam metal $8–16 per sq ft
  { itemId: "metal-roofing-installed", trade: "roofing", description: "Metal roofing, tear-off + install", unit: "sq ft", soc: ROOFER, laborHours: b(0.04, 0.06, 0.09), materials: b(4.5, 7, 11) },
  // Whole-project band for unknown size/material — wide by design.
  // sanity: full replacement $6,000–18,000 (~1,700 sq ft equivalent)
  { itemId: "roof-replacement-total", trade: "roofing", description: "Full roof replacement, size/material unknown", unit: "project", soc: ROOFER, laborHours: b(40, 60, 90), materials: b(3500, 5500, 9000) },
  // Small-job overhead baked into hours. sanity: patch repair $300–1,200
  { itemId: "roof-repair-patch", trade: "roofing", description: "Localized roof repair, per sq ft of patch", unit: "sq ft", soc: ROOFER, laborHours: b(0.06, 0.1, 0.16), materials: b(1.5, 3, 6) },
  // sanity: seamless aluminum gutters $6–14 per LF
  { itemId: "gutter-install-aluminum", trade: "roofing", description: "Seamless aluminum gutters", unit: "linear foot", soc: ROOFER, laborHours: b(0.05, 0.08, 0.12), materials: b(3, 5, 8) },

  // --- flooring ---------------------------------------------------------
  // sanity: solid hardwood $8–17 per sq ft installed
  { itemId: "hardwood-installed", trade: "flooring", description: "Solid hardwood, supplied + installed", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.04, 0.06, 0.09), materials: b(4, 7, 11) },
  // sanity: laminate $3–8 per sq ft installed
  { itemId: "laminate-installed", trade: "flooring", description: "Laminate flooring, supplied + installed", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.025, 0.035, 0.05), materials: b(1.5, 3, 5) },
  // sanity: luxury vinyl plank $4–9 per sq ft installed
  { itemId: "lvp-installed", trade: "flooring", description: "Luxury vinyl plank, supplied + installed", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.025, 0.035, 0.05), materials: b(2, 3.5, 6) },
  // sanity: carpet incl. pad $3.50–8 per sq ft installed
  { itemId: "carpet-installed", trade: "flooring", description: "Carpet + pad, supplied + installed", unit: "sq ft", soc: CARPET_INSTALLER, laborHours: b(0.015, 0.025, 0.04), materials: b(2, 4, 6.5) },
  // sanity: ceramic/porcelain tile $10–25 per sq ft installed
  { itemId: "tile-installed", trade: "flooring", description: "Ceramic/porcelain tile, supplied + installed", unit: "sq ft", soc: TILE_SETTER, laborHours: b(0.08, 0.12, 0.18), materials: b(3, 6, 11) },
  // 47-2043 is suppressed in many states — falls back to national wages.
  // sanity: sand + refinish $3–8 per sq ft
  { itemId: "hardwood-refinishing", trade: "flooring", description: "Hardwood sand + refinish", unit: "sq ft", soc: FLOOR_SANDER, laborHours: b(0.03, 0.045, 0.07), materials: b(0.8, 1.5, 2.5) },
  // SCOPE_ADD_ONS — priced per sq ft of the base job's area
  // sanity: flooring tear-out + disposal $1–3 per sq ft
  { itemId: "flooring-removal-only", trade: "flooring", description: "Old flooring removal + disposal", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.015, 0.025, 0.04), materials: b(0.2, 0.4, 0.8) },
  // sanity: subfloor repair $2–6 per affected sq ft
  { itemId: "subfloor-repair", trade: "flooring", description: "Subfloor repair/replacement", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.03, 0.05, 0.08), materials: b(1, 2, 3.5) },
  // sanity: self-leveling underlayment $2–5 per sq ft
  { itemId: "floor-leveling", trade: "flooring", description: "Floor leveling compound", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.02, 0.035, 0.06), materials: b(1, 2, 3.5) },

  // --- windows ---------------------------------------------------------
  // Band is for a full-unit INSERT (frame stays). Glass-only and full-frame
  // tear-out are reached via windowScopeScale off this reference, not separate
  // rows. sanity: vinyl insert $500–1,300 installed
  { itemId: "vinyl-window-replacement", trade: "windows", description: "Vinyl replacement window, insert", unit: "each", soc: CARPENTER, laborHours: b(2, 3, 4.5), materials: b(300, 540, 950) },
  // sanity: bay/bow window $2,000–6,000 installed
  { itemId: "bay-bow-window-replacement", trade: "windows", description: "Bay/bow window replacement", unit: "each", soc: CARPENTER, laborHours: b(8, 12, 18), materials: b(1200, 2200, 4000) },
  // sanity: casement window $500–1,400 installed
  { itemId: "casement-window-replacement", trade: "windows", description: "Casement window replacement", unit: "each", soc: CARPENTER, laborHours: b(2, 3, 4.5), materials: b(350, 600, 1000) },
  // Includes foundation cut + well. sanity: egress install $2,500–6,000
  { itemId: "egress-window-installation", trade: "windows", description: "Egress window, incl. cut + well", unit: "each", soc: CARPENTER, laborHours: b(12, 18, 26), materials: b(1000, 1800, 3200) },

  // --- doors -----------------------------------------------------------
  // sanity: french door pair $1,500–4,500 installed
  { itemId: "french-door-installation", trade: "doors", description: "French doors, supplied + installed", unit: "pair", soc: CARPENTER, laborHours: b(5, 8, 12), materials: b(1200, 2200, 4000) },
  // sanity: sliding patio door $1,200–3,500 installed
  { itemId: "sliding-patio-door", trade: "doors", description: "Sliding patio door, supplied + installed", unit: "each", soc: CARPENTER, laborHours: b(4, 6, 9), materials: b(1000, 1700, 3000) },
  // sanity: steel entry door $600–1,800 installed
  { itemId: "exterior-door-steel", trade: "doors", description: "Steel exterior door, supplied + installed", unit: "each", soc: CARPENTER, laborHours: b(3, 5, 8), materials: b(350, 650, 1200) },
  // sanity: hollow-core interior door $150–500 installed
  { itemId: "interior-door-hollow-core", trade: "doors", description: "Hollow-core interior door, supplied + installed", unit: "each", soc: CARPENTER, laborHours: b(1.5, 2.5, 4), materials: b(80, 150, 280) },
  // Specialty installers, not carpenters — general-maintenance wage is the
  // closest OEWS fit. sanity: single garage door $700–2,200 installed
  { itemId: "garage-door-single", trade: "doors", description: "Single garage door, supplied + installed", unit: "each", soc: MAINTENANCE, laborHours: b(3, 4.5, 7), materials: b(600, 1000, 1800) },

  // --- landscaping -------------------------------------------------------
  // sanity: sod $1–2.50 per sq ft installed
  { itemId: "sod-installation", trade: "landscaping", description: "Sod, supplied + installed", unit: "sq ft", soc: LANDSCAPER, laborHours: b(0.008, 0.012, 0.02), materials: b(0.4, 0.7, 1.1) },
  // Size drives the huge spread; hours are crew-hours. sanity: $300–2,000
  { itemId: "tree-removal", trade: "landscaping", description: "Tree removal, size unknown", unit: "each", soc: LANDSCAPER, laborHours: b(6, 14, 28), materials: b(50, 150, 400) },
  // sanity: irrigation $600–1,700 per zone
  { itemId: "irrigation-system-per-zone", trade: "landscaping", description: "Irrigation system, per zone", unit: "each", soc: LANDSCAPER, laborHours: b(6, 10, 15), materials: b(250, 450, 800) },
  // sanity: paver patio $10–30 per sq ft
  { itemId: "paver-patio-installation", trade: "landscaping", description: "Paver patio, incl. base prep", unit: "sq ft", soc: LANDSCAPER, laborHours: b(0.15, 0.25, 0.4), materials: b(4, 7, 12) },
  // sanity: mulch delivered + spread $45–130 per cu yd
  { itemId: "mulch-installation", trade: "landscaping", description: "Mulch, delivered + spread", unit: "cubic yard", soc: LANDSCAPER, laborHours: b(0.5, 0.75, 1.2), materials: b(25, 40, 65) },

  // --- countertops (vanity JOB_COMPONENT) --------------------------------
  // sanity: laminate countertop $25–70 per sq ft installed
  { itemId: "laminate-countertop-installed", trade: "countertops", description: "Laminate countertop, supplied + installed", unit: "sq ft", soc: CARPENTER, laborHours: b(0.18, 0.28, 0.42), materials: b(10, 17, 30) },

  // =====================================================================
  // AUTO & MOTO
  // =====================================================================
  // Added 2026-07-20. Before this the vertical had no priced items at all and
  // every auto search fell through to priceComingSoonText().
  //
  // Same labor+materials shape as the home trades, with two differences:
  //   - laborHours are FLAT-RATE BOOK hours (what the shop bills), not actual
  //     wrench time. That's what a customer is charged, so it's the honest
  //     input; it also makes the numbers comparable to published estimates.
  //   - the wage→rate multiplier comes from TRADE_BURDEN, not the 2.2 used for
  //     construction (see the comment there).
  //
  // Bands assume a common mid-size sedan / light truck with a widely stocked
  // aftermarket part. Vehicle make is the single largest unmodelled driver —
  // a European or EV variant can run 2–3x — so these carry lower confidence
  // than the home items until the app collects vehicle year/make/model.

  // --- auto repair & maintenance ----------------------------------------
  // sanity: full-synthetic oil change $65–125
  { itemId: "oil-change-synthetic", trade: "auto-repair", description: "Full-synthetic oil and filter change", unit: "each", soc: AUTO_TECH, laborHours: b(0.3, 0.4, 0.45), materials: b(35, 40, 48) },
  // sanity: brake pads, one axle $330–390 (RepairPal national)
  { itemId: "brake-pads-per-axle", trade: "auto-repair", description: "Brake pad replacement, one axle", unit: "axle", soc: AUTO_TECH, laborHours: b(1, 1.3, 1.6), materials: b(95, 175, 260) },
  // sanity: pads + rotors, one axle $450–750
  { itemId: "brake-pads-rotors-per-axle", trade: "auto-repair", description: "Brake pads and rotors, one axle", unit: "axle", soc: AUTO_TECH, laborHours: b(1.3, 1.7, 2.2), materials: b(190, 370, 560) },
  // sanity: battery replaced $150–450 incl. unit
  { itemId: "battery-replacement", trade: "auto-repair", description: "Car battery, supplied + installed", unit: "each", soc: AUTO_TECH, laborHours: b(0.3, 0.5, 0.8), materials: b(120, 180, 300) },
  // sanity: alternator $802–1,073 (RepairPal national)
  { itemId: "alternator-replacement", trade: "auto-repair", description: "Alternator replacement", unit: "each", soc: AUTO_TECH, laborHours: b(1.5, 2.2, 3.5), materials: b(320, 600, 1000) },
  // sanity: starter $566–787 (RepairPal national)
  { itemId: "starter-replacement", trade: "auto-repair", description: "Starter motor replacement", unit: "each", soc: AUTO_TECH, laborHours: b(1.2, 1.9, 3), materials: b(280, 520, 850) },
  // sanity: water pump $888–1,139 (RepairPal national)
  { itemId: "water-pump-replacement", trade: "auto-repair", description: "Water pump replacement", unit: "each", soc: AUTO_TECH, laborHours: b(2.5, 3.5, 5.5), materials: b(260, 530, 900) },
  // Sources disagree sharply: RepairPal $1,353–1,528 vs ConsumerAffairs-class
  // guides $600–1,200. Band set to span both; the held-out validation set is
  // the tiebreaker, not a hand-picked source. sanity: $900–1,500
  { itemId: "radiator-replacement", trade: "auto-repair", description: "Radiator replacement", unit: "each", soc: AUTO_TECH, laborHours: b(2, 3, 4.5), materials: b(380, 700, 1200) },
  // sanity: timing belt $700–1,200 (kit with water pump runs to $1,500)
  { itemId: "timing-belt-replacement", trade: "auto-repair", description: "Timing belt replacement", unit: "each", soc: AUTO_TECH, laborHours: b(3.5, 5, 7.5), materials: b(180, 300, 550) },
  // sanity: spark plugs $100–250 (4-cyl; V6/V8 with intake removal runs higher)
  { itemId: "spark-plug-replacement", trade: "auto-repair", description: "Spark plug replacement", unit: "each", soc: AUTO_TECH, laborHours: b(0.7, 1, 1.8), materials: b(30, 55, 110) },
  // sanity: A/C recharge $200–350 (R-1234yf systems run to $500)
  { itemId: "ac-recharge-auto", trade: "auto-repair", description: "Air conditioning evacuate + recharge", unit: "each", soc: AUTO_TECH, laborHours: b(0.6, 0.9, 1.4), materials: b(70, 130, 240) },
  // sanity: transmission fluid service $80–250
  { itemId: "transmission-fluid-change", trade: "auto-repair", description: "Transmission fluid change", unit: "each", soc: AUTO_TECH, laborHours: b(0.6, 0.9, 1.4), materials: b(35, 55, 110) },
  // sanity: catalytic converter $800–2,500
  { itemId: "catalytic-converter-replacement", trade: "auto-repair", description: "Catalytic converter replacement", unit: "each", soc: AUTO_TECH, laborHours: b(1.5, 2.5, 4), materials: b(500, 1050, 2200) },
  // sanity: O2 sensor $150–300 per sensor
  { itemId: "oxygen-sensor-replacement", trade: "auto-repair", description: "Oxygen sensor replacement", unit: "each", soc: AUTO_TECH, laborHours: b(0.5, 0.8, 1.3), materials: b(60, 110, 220) },
  // sanity: muffler / exhaust section $150–600
  { itemId: "muffler-exhaust-repair", trade: "auto-repair", description: "Muffler or exhaust section replacement", unit: "each", soc: AUTO_TECH, laborHours: b(0.8, 1.3, 2.2), materials: b(90, 175, 350) },
  // sanity: struts or shocks, one axle $450–900
  { itemId: "strut-shock-per-axle", trade: "auto-repair", description: "Struts or shocks, one axle", unit: "axle", soc: AUTO_TECH, laborHours: b(1.5, 2.2, 3.5), materials: b(200, 355, 600) },
  // sanity: CV axle $300–800
  { itemId: "cv-axle-replacement", trade: "auto-repair", description: "CV axle replacement", unit: "each", soc: AUTO_TECH, laborHours: b(1.2, 1.8, 2.8), materials: b(120, 260, 480) },
  // sanity: fuel pump $700–1,400
  { itemId: "fuel-pump-replacement", trade: "auto-repair", description: "Fuel pump replacement", unit: "each", soc: AUTO_TECH, laborHours: b(2, 3, 4.5), materials: b(300, 550, 1000) },
  // sanity: clutch $1,000–2,000
  { itemId: "clutch-replacement", trade: "auto-repair", description: "Clutch replacement", unit: "each", soc: AUTO_TECH, laborHours: b(4, 5.5, 8), materials: b(350, 660, 1200) },
  // Labor only — the scan and the diagnosis, credited against the repair by
  // most shops. sanity: diagnostic fee $75–180
  { itemId: "auto-diagnostic-fee", trade: "auto-repair", description: "Diagnostic scan and inspection", unit: "each", soc: AUTO_TECH, laborHours: b(0.7, 0.9, 1.2), materials: b(0, 0, 0) },
  // category-general fallback: posted door rate, small shop-supplies allowance
  { itemId: "auto-labor-hourly", trade: "auto-repair", description: "General automotive labor", unit: "hour", soc: AUTO_TECH, laborHours: b(1, 1, 1), materials: b(0, 5, 15) },

  // --- tires -------------------------------------------------------------
  // sanity: one mid-range tire fitted $150–350
  { itemId: "tire-replacement-per-tire", trade: "auto-tires", description: "Tire supplied, mounted + balanced", unit: "each", soc: AUTO_TECH, laborHours: b(0.25, 0.35, 0.5), materials: b(110, 180, 300) },
  // sanity: mount + balance $15–45 per tire (tire not included)
  { itemId: "tire-mount-balance-per-tire", trade: "auto-tires", description: "Mount and balance, tire not included", unit: "each", soc: AUTO_TECH, laborHours: b(0.15, 0.2, 0.28), materials: b(2, 4, 8) },
  // sanity: rotation $20–60
  { itemId: "tire-rotation", trade: "auto-tires", description: "Tire rotation, four wheels", unit: "each", soc: AUTO_TECH, laborHours: b(0.2, 0.3, 0.45), materials: b(0, 2, 5) },
  // sanity: puncture repair $15–45
  { itemId: "flat-tire-repair", trade: "auto-tires", description: "Flat repair, patch/plug", unit: "each", soc: AUTO_TECH, laborHours: b(0.15, 0.22, 0.35), materials: b(2, 4, 8) },
  // sanity: four-wheel alignment $80–200
  { itemId: "wheel-alignment", trade: "auto-tires", description: "Wheel alignment", unit: "each", soc: AUTO_TECH, laborHours: b(0.6, 0.85, 1.2), materials: b(0, 10, 25) },
  // sanity: TPMS sensor $50–130 per wheel
  { itemId: "tpms-sensor-per-wheel", trade: "auto-tires", description: "TPMS sensor, supplied + installed", unit: "each", soc: AUTO_TECH, laborHours: b(0.2, 0.3, 0.45), materials: b(30, 48, 90) },

  // --- cleaning & detailing ----------------------------------------------
  // sanity: full interior + exterior detail $150–400
  { itemId: "full-detail", trade: "auto-detailing", description: "Full detail, interior + exterior", unit: "each", soc: VEHICLE_CLEANER, laborHours: b(2.5, 4, 6), materials: b(20, 35, 60) },
  // sanity: interior-only detail $100–250
  { itemId: "interior-detail", trade: "auto-detailing", description: "Interior detail", unit: "each", soc: VEHICLE_CLEANER, laborHours: b(1.5, 2.4, 3.5), materials: b(12, 22, 40) },
  // sanity: exterior detail + wax $75–200
  { itemId: "exterior-detail-wax", trade: "auto-detailing", description: "Exterior detail and wax", unit: "each", soc: VEHICLE_CLEANER, laborHours: b(1.2, 1.8, 2.8), materials: b(10, 20, 38) },
  // sanity: attended wash $15–40
  { itemId: "car-wash-basic", trade: "auto-detailing", description: "Basic wash and dry", unit: "each", soc: VEHICLE_CLEANER, laborHours: b(0.25, 0.35, 0.5), materials: b(2, 4, 8) },
  // sanity: ceramic coating $700–1,850
  { itemId: "ceramic-coating", trade: "auto-detailing", description: "Ceramic coating application", unit: "each", soc: VEHICLE_CLEANER, laborHours: b(6, 10, 16), materials: b(300, 500, 900) },
  // sanity: headlight restoration $100–200 per pair
  { itemId: "headlight-restoration", trade: "auto-detailing", description: "Headlight lens restoration, pair", unit: "pair", soc: VEHICLE_CLEANER, laborHours: b(0.8, 1.3, 2), materials: b(15, 28, 50) },
  // sanity: paint correction $300–1,000
  { itemId: "paint-correction", trade: "auto-detailing", description: "Machine paint correction", unit: "each", soc: VEHICLE_CLEANER, laborHours: b(4, 8, 12), materials: b(25, 45, 85) },

  // --- body & paint ------------------------------------------------------
  // sanity: bumper scuff/scratch repair $150–500
  { itemId: "bumper-repair-scuff", trade: "auto-body", description: "Bumper scuff or scratch repair", unit: "each", soc: BODY_REPAIRER, laborHours: b(1.5, 2.5, 4), materials: b(40, 85, 170) },
  // sanity: bumper replaced, painted + fitted $800–2,500
  { itemId: "bumper-replacement", trade: "auto-body", description: "Bumper cover replaced, painted + fitted", unit: "each", soc: BODY_REPAIRER, laborHours: b(3, 4.5, 7), materials: b(450, 900, 1800) },
  // sanity: paintless dent repair $150–400
  { itemId: "pdr-dent-repair", trade: "auto-body", description: "Paintless dent repair", unit: "each", soc: BODY_REPAIRER, laborHours: b(1.5, 2.5, 4), materials: b(10, 25, 55) },
  // sanity: one panel resprayed + blended $200–1,500
  { itemId: "panel-respray", trade: "auto-body", description: "Single panel respray, blended", unit: "each", soc: BODY_REPAIRER, laborHours: b(4, 6.5, 10), materials: b(40, 90, 200) },
  // Standard basecoat-clearcoat tier, not the $500 production-shop tier nor
  // show-quality. sanity: $1,500–5,000
  { itemId: "full-respray", trade: "auto-body", description: "Full vehicle respray, standard quality", unit: "each", soc: BODY_REPAIRER, laborHours: b(22, 32, 50), materials: b(300, 600, 1300) },
  // sanity: collision panel replaced $600–2,000
  { itemId: "collision-panel-replacement", trade: "auto-body", description: "Collision panel replaced + painted", unit: "each", soc: BODY_REPAIRER, laborHours: b(4, 6, 9.5), materials: b(300, 600, 1200) },

  // --- glass -------------------------------------------------------------
  // sanity: windshield replaced $250–800 (avg ~$450)
  { itemId: "windshield-replacement", trade: "auto-glass", description: "Windshield replacement", unit: "each", soc: GLASS_INSTALLER, laborHours: b(1.2, 1.8, 2.8), materials: b(180, 290, 520) },
  // sanity: chip/star repair $60–150
  { itemId: "windshield-chip-repair", trade: "auto-glass", description: "Windshield chip repair", unit: "each", soc: GLASS_INSTALLER, laborHours: b(0.5, 0.8, 1.2), materials: b(20, 35, 60) },
  // Increasingly mandatory after a windshield swap on any car with lane-keep
  // or adaptive cruise. sanity: $150–400
  { itemId: "adas-recalibration", trade: "auto-glass", description: "ADAS camera recalibration", unit: "each", soc: GLASS_INSTALLER, laborHours: b(1, 1.5, 2.5), materials: b(90, 165, 320) },
  // sanity: door/quarter glass $200–500
  { itemId: "side-window-replacement", trade: "auto-glass", description: "Side or rear window replacement", unit: "each", soc: GLASS_INSTALLER, laborHours: b(1, 1.5, 2.4), materials: b(110, 195, 350) },

  // --- motorcycle --------------------------------------------------------
  // A motorcycle is NOT a small car, and pricing it as one was the bug that
  // prompted these entries (2026-07-20): "replace tires" on the Moto filter
  // priced four car tires at ~$890 for a job that is two moto tires at ~$440.
  // Only the jobs where moto differs enough to matter get their own row; see
  // MOTO_VARIANTS in pricingEngine.ts for the auto→moto item mapping. Anything
  // without a variant keeps the auto item, which is the honest default for
  // work that genuinely is comparable.
  // sanity: one moto tire supplied + fitted $160–300
  { itemId: "moto-tire-replacement-per-tire", trade: "moto-tires", description: "Motorcycle tire, supplied + fitted", unit: "each", soc: MOTO_MECH, laborHours: b(0.4, 0.55, 0.8), materials: b(120, 160, 230) },
  // sanity: mount + balance $30–60 per wheel, tire carried in
  { itemId: "moto-tire-mount-balance-per-tire", trade: "moto-tires", description: "Motorcycle tire mount and balance, tire not included", unit: "each", soc: MOTO_MECH, laborHours: b(0.3, 0.4, 0.55), materials: b(2, 4, 8) },
  // sanity: moto oil + filter change $40–100
  { itemId: "moto-oil-change", trade: "moto-repair", description: "Motorcycle oil and filter change", unit: "each", soc: MOTO_MECH, laborHours: b(0.4, 0.5, 0.7), materials: b(12, 18, 30) },
  // Priced per wheel, not per axle — a bike's front and rear are separate jobs
  // with different pad sets. sanity: $130–300 per wheel
  { itemId: "moto-brake-pads-per-wheel", trade: "moto-repair", description: "Motorcycle brake pads, one wheel", unit: "each", soc: MOTO_MECH, laborHours: b(1, 1.4, 2), materials: b(35, 50, 85) },
  // sanity: chain + sprockets, parts and labor $150–450
  { itemId: "moto-chain-sprocket", trade: "moto-repair", description: "Motorcycle chain and sprocket set", unit: "each", soc: MOTO_MECH, laborHours: b(1, 1.5, 2.5), materials: b(90, 120, 200) },
];

export const CATALOG_BY_ID: Map<string, CostCatalogEntry> = new Map(
  COST_CATALOG.map((e) => [e.itemId, e]),
);
