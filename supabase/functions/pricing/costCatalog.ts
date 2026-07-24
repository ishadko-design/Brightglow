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
  laborHours: Band;  // CREW-hours per unit — the MARGINAL cost of one more unit
  materials: Band;   // USD per unit, incl. typical contractor markup
  /** One-time job cost that does not scale with quantity: mobilization, demo
   *  and disposal, protection, layout, edge and trim detail, cleanup. Set it on
   *  any item priced per sq ft / per each where a small job is not simply a
   *  fraction of a large one — which is most measured work. When present, pull
   *  the per-unit bands DOWN to the marginal rate, or large jobs inflate by the
   *  setup they used to have baked in. */
  setup?: { hours: Band; materials: Band };
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
  // Mold remediation bills well above what its wage grade implies: the crew
  // arrives with HEPA air scrubbers, negative-air machines and dehumidifiers,
  // carries certification and pollution liability insurance, and pays to
  // dispose of what it removes. 2.8 × the $23.84 proxy median lands at ~$67/hr,
  // against a $75–110/hr market — the balance sits in the per-job setup, which
  // is where the equipment and disposal actually live.
  "remediation": 2.8,
  // Appliance service is a truck-roll business like the auto trades, not a
  // construction trade: a stocked parts van, a flat-rate repair book, and a
  // diagnostic that gets billed whether or not the repair proceeds. 3.4 × the
  // $23.84 national median lands at ~$81/hr, with p25/p75 giving $67–$102 —
  // inside the $50–150/hr appliance-tech labor range published for 2026.
  "appliance": 3.4,
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
// Home Appliance Repairers are SOC 49-9031, which ingest-oews.py does not pull
// — adding it means re-running the ingest against the BLS release, not editing
// the generated tables. 49-9071 is the standing proxy: nationally $23.84
// median against 49-9031's $22–24, and it is present in the state AND metro
// tables, so appliance work still prices locally. Swap this one constant if
// 49-9031 is ever ingested.
const APPLIANCE_TECH = MAINTENANCE;
// Same story for the two Mold & Pest trades. Hazardous Materials Removal
// Workers (47-4041) and Pest Control Workers (37-2021) are both absent from the
// ingested tables — national, state AND metro — so each takes the closest
// ingested occupation as a documented proxy:
//   remediation → 49-9071 at $23.84 median, against 47-4041's ~$24–25. A
//     remediation crew is demo-and-cleanup labor, which is what 49-9071 is.
//   pest        → 37-3011 at $18.82 median, against 37-2021's ~$19–20. Both are
//     route-based outdoor service work at the same wage grade.
// Swap either constant if ingest-oews.py is ever re-run with its real SOC.
const REMEDIATION = MAINTENANCE;
const PEST_TECH = LANDSCAPER;
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
  { itemId: "fixture-install", trade: "plumbing", description: "Replace one plumbing fixture (faucet, toilet, sink)", unit: "each", soc: PLUMBER, laborHours: b(0.55, 1.1, 1.65), materials: b(66, 137.5, 330), setup: { hours: b(0.45, 0.9, 1.35), materials: b(54, 112.5, 270) } },
  // sanity: leak/clog service call $150–700
  { itemId: "pipe-repair", trade: "plumbing", description: "Localized pipe/drain repair or clog clearing", unit: "project", soc: PLUMBER, laborHours: b(1.5, 3, 6), materials: b(30, 80, 250) },
  // Plumbing REPAIRS, added 2026-07-22. The category modelled installs only, so
  // the most-called-about jobs in the trade either priced as a replacement or
  // not at all: "my toilet keeps running" quoted a $433 fixture swap for a $30
  // flapper, and "no hot water" returned nothing. Bands and setup shares from
  // docs/pricing-research/anchors-verified.json (Fixr, HomeGuide, HomeAdvisor,
  // Angi 2025-26).
  //
  // Setup carries most of these on purpose: a service call is mostly the truck
  // roll and the diagnosis, so a second toilet on the same visit costs a
  // fraction of the first. That is what the setupShare in the research measures.
  // sanity: running-toilet repair $80–400 (flapper/fill valve/flush valve)
  { itemId: "toilet-repair-internals", trade: "plumbing", description: "Running toilet — flapper, fill valve or flush valve", unit: "each", soc: PLUMBER, laborHours: b(0.2, 0.35, 0.6), materials: b(10, 20, 45), setup: { hours: b(1, 1.5, 2.2), materials: b(15, 30, 60) } },
  // sanity: leaky faucet repair $100–400 (cartridge/washer/O-ring)
  { itemId: "faucet-repair-cartridge", trade: "plumbing", description: "Leaky faucet — cartridge, washer or O-ring rebuild", unit: "each", soc: PLUMBER, laborHours: b(0.35, 0.6, 0.9), materials: b(18, 42, 75), setup: { hours: b(1.2, 2.05, 2.9), materials: b(25, 58, 105) } },
  // "No hot water" is usually a $150–500 thermocouple, element, thermostat or
  // T&P valve — not the $1,500–3,000 replacement it used to quote.
  // sanity: water heater repair $150–900
  { itemId: "water-heater-repair", trade: "plumbing", description: "Water heater repair — thermocouple, element, thermostat, T&P valve", unit: "each", soc: PLUMBER, laborHours: b(0.7, 1.2, 2.1), materials: b(25, 65, 190), setup: { hours: b(1.3, 1.8, 3.4), materials: b(25, 70, 210) } },
  // sanity: pull-and-reset with new wax ring $150–350
  { itemId: "toilet-reset-wax-ring", trade: "plumbing", description: "Toilet leaking at base — pull, reset, new wax ring", unit: "each", soc: PLUMBER, laborHours: b(0.4, 0.6, 0.9), materials: b(10, 18, 30), setup: { hours: b(1.2, 1.8, 2.6), materials: b(20, 35, 60) } },
  // Sharply different from a $1,000–2,500 valve BODY replacement that opens the
  // wall; default here unless the description mentions tile or wall access.
  // sanity: shower/tub cartridge $100–400
  { itemId: "shower-valve-cartridge", trade: "plumbing", description: "Shower/tub valve cartridge replacement", unit: "each", soc: PLUMBER, laborHours: b(0.3, 0.5, 0.9), materials: b(15, 35, 75), setup: { hours: b(1, 1.7, 2.6), materials: b(25, 50, 110) } },
  // Two-tier: unjam/reset at the low end, full replacement at the high end.
  // sanity: garbage disposal repair or replacement $150–650
  { itemId: "garbage-disposal-service", trade: "plumbing", description: "Garbage disposal — unjam, repair or replace", unit: "each", soc: PLUMBER, laborHours: b(0.5, 0.9, 1.5), materials: b(30, 130, 350), setup: { hours: b(1, 1.6, 2.4), materials: b(20, 45, 100) } },
  // sanity: sump pump repair or replacement $250–1,200
  { itemId: "sump-pump-service", trade: "plumbing", description: "Sump pump repair or replacement", unit: "each", soc: PLUMBER, laborHours: b(1, 1.8, 3), materials: b(80, 240, 600), setup: { hours: b(1.2, 2, 3), materials: b(40, 90, 200) } },
  // Genuinely billed as a DIAGNOSTIC, separate from whatever repair it leads to
  // — the engine has no two-stage output yet, so this prices the finding only.
  // sanity: leak detection $75–200 per hour
  { itemId: "leak-detection", trade: "plumbing", description: "Hidden leak detection — acoustic/thermal, diagnosis only", unit: "hour", soc: PLUMBER, laborHours: b(1, 1, 1), materials: b(0, 5, 15), setup: { hours: b(0.4, 0.7, 1.2), materials: b(15, 35, 80) } },
  // sanity: burst/frozen pipe repair $200–1,500 per section (before any
  // after-hours multiplier, which the engine cannot express yet)
  { itemId: "burst-pipe-repair", trade: "plumbing", description: "Burst or frozen pipe repair, per section", unit: "each", soc: PLUMBER, laborHours: b(1, 2, 4), materials: b(40, 110, 350), setup: { hours: b(1.5, 2.5, 4), materials: b(30, 70, 180) } },
  // sanity: whole-house PEX repipe $4,000–15,000 for ~1,500 sq ft
  { itemId: "whole-house-repipe-pex", trade: "plumbing", description: "Whole-house PEX repipe", unit: "sq ft", soc: PLUMBER, laborHours: b(0.027, 0.045, 0.072), materials: b(0.72, 1.35, 2.25), setup: { hours: b(4.5, 7.5, 12), materials: b(120, 225, 375) } },
  // sanity: sewer line replacement $50–250 per linear foot (open trench)
  { itemId: "sewer-line-replacement", trade: "plumbing", description: "Sewer lateral replacement, open trench", unit: "linear foot", soc: PLUMBER, laborHours: b(0.35, 0.56, 0.84), materials: b(10.5, 21, 42), setup: { hours: b(7.5, 12, 18), materials: b(225, 450, 900) } },
  // category-general fallback: one plumber, small parts allowance
  { itemId: "plumber-hourly", trade: "plumbing", description: "General plumbing labor", unit: "hour", soc: PLUMBER, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },
  // vanity JOB_COMPONENT; mid-grade faucet included
  { itemId: "faucet-install-plumbing", trade: "plumbing", description: "Supply and install bathroom faucet", unit: "each", soc: PLUMBER, laborHours: b(1, 1.5, 2.5), materials: b(80, 150, 300) },

  // --- electrical ------------------------------------------------------
  // sanity: 200A panel upgrade $1,800–4,000 (permit/utility coordination in hours)
  { itemId: "panel-upgrade-200amp", trade: "electrical", description: "200-amp service panel upgrade", unit: "project", soc: ELECTRICIAN, laborHours: b(8, 12, 18), materials: b(800, 1300, 2200) },
  // sanity: new/replaced outlet $100–350
  { itemId: "outlet-installation", trade: "electrical", description: "Install or replace an outlet", unit: "each", soc: ELECTRICIAN, laborHours: b(0.4125, 0.6875, 1.375), materials: b(5.5, 13.75, 44), setup: { hours: b(0.3375, 0.5625, 1.125), materials: b(4.5, 11.25, 36) } },
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
  { itemId: "solar-panel-install", trade: "electrical", description: "Rooftop solar PV, per panel, incl. inverter share, racking and permitting", unit: "each", soc: ELECTRICIAN, laborHours: b(0.9, 1.35, 1.95), materials: b(570, 750, 1012.5), setup: { hours: b(6, 9, 13), materials: b(3800, 5000, 6750) } },
  // sanity: whole-house rewire $4–10 per sq ft
  { itemId: "whole-house-rewire", trade: "electrical", description: "Whole-house rewire", unit: "sq ft", soc: ELECTRICIAN, laborHours: b(0.036, 0.054, 0.081), materials: b(0.9, 1.62, 2.7), setup: { hours: b(6, 9, 13.5), materials: b(150, 270, 450) } },
  // sanity: light fixture swap $75–250 (fixture customer-supplied)
  { itemId: "light-fixture-install", trade: "electrical", description: "Install light fixture (fixture not included)", unit: "each", soc: ELECTRICIAN, laborHours: b(0.4125, 0.825, 1.375), materials: b(2.75, 11, 33), setup: { hours: b(0.3375, 0.675, 1.125), materials: b(2.25, 9, 27) } },
  { itemId: "electrician-hourly", trade: "electrical", description: "General electrical labor", unit: "hour", soc: ELECTRICIAN, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },
  // ELECTRICAL REPAIRS + small jobs, added 2026-07-23 from
  // docs/pricing-research/anchors-verified.json. Everything here is dominated by
  // the trip and the diagnosis rather than the part — a breaker is $10 of
  // hardware — which is why the setup shares run high. That is also what makes
  // the second one on the same visit much cheaper, which the engine now models.
  // sanity: breaker replacement / tripping-breaker repair $100–400 per breaker
  { itemId: "circuit-breaker-replacement", trade: "electrical", description: "Circuit breaker replacement / tripping breaker repair", unit: "each", soc: ELECTRICIAN, laborHours: b(0.15, 0.25, 0.45), materials: b(12, 28, 70), setup: { hours: b(0.9, 1.5, 2.5), materials: b(20, 45, 100) } },
  // sanity: light switch / dimmer replacement $75–300 (Fixr is a low outlier at
  // the DIY-part level; the band follows the installed-by-a-pro cluster)
  { itemId: "switch-dimmer-replacement", trade: "electrical", description: "Light switch or dimmer replacement", unit: "each", soc: ELECTRICIAN, laborHours: b(0.15, 0.28, 0.5), materials: b(8, 22, 55), setup: { hours: b(0.55, 1, 1.7), materials: b(14, 32, 70) } },
  // sanity: GFCI outlet install/replace $90–300
  { itemId: "gfci-outlet", trade: "electrical", description: "GFCI outlet installation or replacement", unit: "each", soc: ELECTRICIAN, laborHours: b(0.2, 0.35, 0.6), materials: b(18, 38, 85), setup: { hours: b(0.6, 1.1, 1.9), materials: b(16, 38, 85) } },
  // Low setup share on purpose: these are installed several at a time in one
  // visit, so the marginal can-light carries most of its own cost.
  //
  // UNRESOLVED SCOPE CONFLICT, checked 2026-07-23: this band is the RETROFIT
  // job — a can into an existing ceiling with power already nearby, which is
  // what the consumer aggregators price and what most requests mean. Homewyse
  // quotes $380–529 per light for the same words, ~2.5x higher, because it
  // prices a new install: new circuit, fishing wire, cutting and patching the
  // ceiling. Both are right about different jobs. The engine cannot tell them
  // apart from "install recessed lighting" alone, so it prices the common one
  // and will read low for a from-scratch install. Splitting this needs a
  // clarify question ("is there already a light there?"), not a wider band —
  // averaging the two would be wrong for every request instead of some.
  // sanity: recessed / can light installation $125–330 per light (retrofit)
  { itemId: "recessed-light-install", trade: "electrical", description: "Recessed (can) light installation, retrofit", unit: "each", soc: ELECTRICIAN, laborHours: b(0.7, 1.1, 1.8), materials: b(35, 70, 150), setup: { hours: b(0.25, 0.45, 0.8), materials: b(10, 22, 50) } },
  // sanity: smoke / CO detector install or chirp fix $70–250 per unit
  { itemId: "smoke-detector-install", trade: "electrical", description: "Smoke / carbon monoxide detector install or chirp repair", unit: "each", soc: ELECTRICIAN, laborHours: b(0.2, 0.35, 0.6), materials: b(20, 45, 100), setup: { hours: b(0.45, 0.8, 1.4), materials: b(12, 28, 60) } },
  // The wide band is scope, not geography: sources disagree on whether this is a
  // short run off an existing panel or a long one with a subpanel.
  // sanity: new dedicated circuit / 240V outlet $250–1,100
  { itemId: "dedicated-circuit", trade: "electrical", description: "New dedicated circuit or 240V outlet", unit: "each", soc: ELECTRICIAN, laborHours: b(1.1, 2.2, 4), materials: b(55, 150, 380), setup: { hours: b(0.8, 1.5, 2.6), materials: b(30, 70, 160) } },
  // sanity: doorbell / video doorbell installation $150–500
  { itemId: "doorbell-install", trade: "electrical", description: "Doorbell or video doorbell installation", unit: "each", soc: ELECTRICIAN, laborHours: b(0.35, 0.6, 1), materials: b(25, 60, 140), setup: { hours: b(0.6, 1.1, 1.9), materials: b(18, 42, 95) } },
  // Distinct from outlet-installation, which is a NEW outlet: this is a dead or
  // damaged one, where the work is finding the fault.
  // sanity: outlet repair or replacement $80–350
  { itemId: "outlet-repair", trade: "electrical", description: "Outlet repair or replacement (dead outlet)", unit: "each", soc: ELECTRICIAN, laborHours: b(0.15, 0.28, 0.5), materials: b(8, 20, 50), setup: { hours: b(0.6, 1.15, 2), materials: b(15, 35, 80) } },
  // Billed as its own visit — sources disagree on whether the fee covers the
  // first hour, so the band spans both conventions.
  // sanity: electrical troubleshooting / diagnostic call $75–160 per hour
  { itemId: "electrical-diagnostic", trade: "electrical", description: "Electrical troubleshooting / diagnostic service call", unit: "hour", soc: ELECTRICIAN, laborHours: b(1, 1, 1), materials: b(0, 8, 25), setup: { hours: b(0.5, 0.85, 1.4), materials: b(10, 22, 50) } },
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

  // --- appliances ------------------------------------------------------
  // Added 2026-07-22. Appliance work had no home in the taxonomy at all, so
  // "replace my dishwasher" classified into Plumbing, found no entry, fell to
  // plumbing.general and was declined by the general-fallback guard — a
  // top-of-funnel request answered with silence. It is not an electrician's
  // trade or a plumber's; appliance repair companies are their own trade with
  // their own businesses, hence its own category rather than more Electrical
  // rows.
  //
  // Every item carries `setup`: an appliance call is mostly the truck roll and
  // the diagnosis, so a second appliance on the same visit costs a fraction of
  // the first. Same shape as the plumbing repairs, and the reason the flat
  // "$75–125 diagnostic fee" the market quotes is not modelled as its own
  // item — it is the setup band on every entry below.
  //
  // The install items EXCLUDE the appliance itself. A dishwasher is bought at
  // retail, not from the installer, and folding a $400–1,500 unit into a labor
  // quote would triple every number for a cost the user has usually already
  // paid. Anchors are labor-and-connections only, which is what the trade
  // actually quotes.
  // sanity: dishwasher repair $115–400 (pump, inlet valve, door seal, board)
  { itemId: "dishwasher-repair", trade: "appliance", description: "Dishwasher repair — pump, inlet valve, door seal or control board", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.5, 0.8, 1.2), materials: b(20, 75, 160), setup: { hours: b(0.5, 0.7, 1), materials: b(0, 0, 0) } },
  // sanity: dishwasher swap $150–450, unit not included (existing hookup)
  { itemId: "dishwasher-install", trade: "appliance", description: "Replace dishwasher in existing opening (unit not included)", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.8, 1.2, 1.8), materials: b(20, 45, 90), setup: { hours: b(0.5, 0.7, 1), materials: b(0, 10, 25) } },
  // First-time install: no existing supply, drain tee or dedicated circuit.
  // The real cost fork on a dishwasher job, and a scope add-on rather than its
  // own job type — the customer asks for a dishwasher, not for a supply line.
  // Band anchored to plumber-run new-hookup pricing; it prices on the
  // appliance trade because add-ons must share the base job's trade.
  // sanity: new dishwasher hookup (supply + drain + circuit) $150–600
  { itemId: "dishwasher-new-hookup", trade: "appliance", description: "New dishwasher hookup — supply line, drain tee and circuit", unit: "each", soc: APPLIANCE_TECH, laborHours: b(1.5, 2.5, 4), materials: b(40, 90, 200) },
  // sanity: refrigerator repair $200–650 (compressor jobs run to the top)
  { itemId: "refrigerator-repair", trade: "appliance", description: "Refrigerator repair — compressor, evaporator fan, defrost or control board", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.8, 1.2, 2), materials: b(60, 190, 420), setup: { hours: b(0.5, 0.7, 1), materials: b(0, 0, 0) } },
  // sanity: washing machine repair $120–500 (pump, belt, valve, lid switch)
  { itemId: "washer-repair", trade: "appliance", description: "Washing machine repair — drain pump, belt, inlet valve or lid switch", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.6, 1, 1.6), materials: b(25, 85, 230), setup: { hours: b(0.5, 0.7, 1), materials: b(0, 0, 0) } },
  // sanity: dryer repair $100–400 (element, thermal fuse, belt, rollers)
  { itemId: "dryer-repair", trade: "appliance", description: "Dryer repair — heating element, thermal fuse, belt or rollers", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.5, 0.9, 1.4), materials: b(20, 60, 160), setup: { hours: b(0.5, 0.7, 1), materials: b(0, 0, 0) } },
  // sanity: oven/range repair $100–450 (igniter, element, control board)
  { itemId: "oven-range-repair", trade: "appliance", description: "Oven or range repair — igniter, heating element or control board", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.5, 0.9, 1.5), materials: b(25, 80, 200), setup: { hours: b(0.5, 0.7, 1), materials: b(0, 0, 0) } },
  // sanity: washer/dryer hookup $100–300, units not included
  { itemId: "washer-dryer-install", trade: "appliance", description: "Install and hook up washer/dryer (units not included)", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.5, 0.8, 1.2), materials: b(15, 35, 75), setup: { hours: b(0.4, 0.6, 0.9), materials: b(0, 0, 0) } },
  // sanity: range/cooktop install $100–400 incl. gas connector or 240V cord
  { itemId: "range-oven-install", trade: "appliance", description: "Install range, cooktop or wall oven (unit not included)", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.5, 0.9, 1.4), materials: b(20, 50, 120), setup: { hours: b(0.4, 0.6, 0.9), materials: b(0, 0, 0) } },
  // sanity: over-the-range microwave install $150–400 incl. vent kit
  { itemId: "otr-microwave-install", trade: "appliance", description: "Install over-the-range microwave, incl. venting (unit not included)", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.8, 1.2, 1.8), materials: b(15, 35, 80), setup: { hours: b(0.4, 0.6, 0.9), materials: b(0, 0, 0) } },
  // The one appliance job that is a fire-safety call rather than a breakdown,
  // and the one people search by name.
  // sanity: dryer vent cleaning $100–200
  { itemId: "dryer-vent-cleaning", trade: "appliance", description: "Dryer vent cleaning", unit: "each", soc: APPLIANCE_TECH, laborHours: b(0.6, 0.9, 1.3), materials: b(5, 10, 25), setup: { hours: b(0.3, 0.5, 0.7), materials: b(0, 0, 0) } },
  // category-general fallback: one tech, small parts allowance
  { itemId: "appliance-labor-hourly", trade: "appliance", description: "General appliance service labor", unit: "hour", soc: APPLIANCE_TECH, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },

  // --- mold & pest -----------------------------------------------------
  // Added 2026-07-22, the last category with no cost data at all. Its
  // CATEGORY_GENERAL was `null` on the grounds that EPCI had no trade for it —
  // an EPCI-era judgment that stopped applying once the in-house catalog became
  // the live path, and was never revisited. The cost of leaving it: the clarify
  // model could not return a category that wasn't in the taxonomy, reached for
  // the nearest available word — "Repair", which belongs to Auto & moto — and a
  // request to remediate mold behind drywall was quoted $274 of car-shop door
  // rate (reported live 2026-07-22).
  //
  // Remediation is priced per square foot of AFFECTED AREA, the unit the trade
  // quotes and the one the clarify chat can actually ask for. Setup carries
  // roughly half the job at the reference size on purpose: containment, the
  // air scrubber, the disposal run and the post-clearance wipe-down are paid
  // once whether the patch is 20 sq ft or 200.
  // sanity: mold remediation $10–25 per sq ft of affected area
  { itemId: "mold-remediation", trade: "remediation", description: "Mold remediation — demo, HEPA cleaning and antimicrobial treatment", unit: "sq ft", soc: REMEDIATION, laborHours: b(0.05, 0.075, 0.11), materials: b(1.2, 2.5, 5), setup: { hours: b(5, 8, 12), materials: b(120, 260, 550) } },
  // Rebuild (new drywall, texture, paint) is deliberately NOT in that band —
  // remediation quotes stop at the clean, dry cavity, and folding a rebuild in
  // would double the number for work the customer often hires separately.
  // sanity: mold inspection with lab sampling $300–1,000
  { itemId: "mold-inspection", trade: "remediation", description: "Mold inspection, incl. air/surface sampling and lab analysis", unit: "each", soc: REMEDIATION, laborHours: b(1.8, 3, 4.8), materials: b(80, 190, 420) },
  // Scope add-on: full containment for a job that would otherwise be a
  // wipe-down. The single biggest fork in a remediation quote.
  // sanity: containment barriers + negative air $400–1,500
  { itemId: "mold-containment", trade: "remediation", description: "Full containment — sealed barriers, negative air, HEPA filtration", unit: "each", soc: REMEDIATION, laborHours: b(1.8, 3.5, 6), materials: b(230, 420, 850) },
  // category-general fallback for the whole category. Hourly, like the other
  // home trades: "Mold & Pest Control" spans a $250 ant treatment and a $2k
  // remediation, so any specific job would be the wrong guess half the time.
  { itemId: "remediation-hourly", trade: "remediation", description: "General mold/remediation labor", unit: "hour", soc: REMEDIATION, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },
  // sanity: one-off pest treatment (ants, roaches, spiders, wasps) $150–400
  { itemId: "pest-treatment", trade: "pest", description: "Single pest treatment — interior and exterior", unit: "each", soc: PEST_TECH, laborHours: b(0.75, 1.2, 2), materials: b(35, 75, 160), setup: { hours: b(0.75, 1.2, 1.8), materials: b(10, 25, 55) } },
  // sanity: termite treatment $500–2,500 (liquid barrier or bait system)
  { itemId: "termite-treatment", trade: "pest", description: "Termite treatment — liquid barrier or bait system", unit: "project", soc: PEST_TECH, laborHours: b(3, 6, 12), materials: b(350, 900, 2100) },
  // sanity: rodent removal + exclusion $200–800
  { itemId: "rodent-exclusion", trade: "pest", description: "Rodent removal and entry-point exclusion", unit: "project", soc: PEST_TECH, laborHours: b(1.5, 3, 6), materials: b(80, 180, 420) },
  // Priced per ROOM — bed bug work is quoted room by room, and a whole-home
  // heat treatment is simply every room at once.
  // sanity: bed bug treatment $250–900 per room
  { itemId: "bed-bug-treatment", trade: "pest", description: "Bed bug treatment, per room", unit: "each", soc: PEST_TECH, laborHours: b(1.2, 2, 3.5), materials: b(70, 160, 350), setup: { hours: b(1, 1.5, 2.5), materials: b(20, 40, 90) } },

  // --- hvac ------------------------------------------------------------
  // sanity: gas furnace replacement $3,000–6,500 installed
  { itemId: "gas-furnace-installed", trade: "hvac", description: "Gas furnace replacement, like-for-like", unit: "project", soc: HVAC_TECH, laborHours: b(8, 12, 18), materials: b(2000, 3200, 5500) },
  // sanity: central AC (condenser + coil) $3,800–7,500
  { itemId: "central-ac-installed", trade: "hvac", description: "Central AC condenser + coil, existing ductwork", unit: "project", soc: HVAC_TECH, laborHours: b(11, 15, 21), materials: b(3300, 4800, 7200) },
  // sanity: ducted heat pump $4,500–9,500
  { itemId: "heat-pump-installed", trade: "hvac", description: "Ducted heat pump system", unit: "project", soc: HVAC_TECH, laborHours: b(10, 16, 24), materials: b(2800, 4500, 8000) },
  // sanity: ductless mini-split $2,000–4,000 per zone
  { itemId: "mini-split-per-zone", trade: "hvac", description: "Ductless mini-split, per zone", unit: "each", soc: HVAC_TECH, laborHours: b(2.8, 4.9, 7), materials: b(840, 1400, 2240), setup: { hours: b(1.2, 2.1, 3), materials: b(360, 600, 960) } },
  // sanity: smart thermostat $200–500 installed incl. unit
  { itemId: "thermostat-installation-smart", trade: "hvac", description: "Smart thermostat, incl. unit", unit: "each", soc: HVAC_TECH, laborHours: b(0.75, 1.25, 2), materials: b(120, 220, 350) },
  // sanity: furnace/AC repair visit $150–800
  { itemId: "furnace-repair", trade: "hvac", description: "HVAC diagnostic + repair", unit: "project", soc: HVAC_TECH, laborHours: b(1, 2.5, 5), materials: b(50, 200, 600) },
  { itemId: "hvac-labor-rate", trade: "hvac", description: "General HVAC labor", unit: "hour", soc: HVAC_TECH, laborHours: b(1, 1, 1), materials: b(0, 10, 30) },
  // HVAC REPAIRS, added 2026-07-23 from docs/pricing-research/anchors-verified.json.
  // The category modelled installs plus one generic "furnace-repair", which the
  // keyword "repair" routed EVERYTHING to — so "AC not cooling", the single most
  // common call in the trade, quoted a furnace job. Same failure as the deck:
  // a plausible number for the wrong job.
  //
  // These are per-project where the trade quotes a whole visit and per-each
  // where a part is named, matching how the research found them published.
  // sanity: AC not cooling, diagnostic + repair $150–700 (sources split on the
  // low end: HomeGuide/This Old House at $150, others near $200)
  { itemId: "ac-repair-diagnostic", trade: "hvac", description: "AC not cooling — diagnostic and repair", unit: "project", soc: HVAC_TECH, laborHours: b(1.2, 2.4, 4.6), materials: b(45, 155, 480) },
  // Cheap part, but the diagnosis and the trip are the job — hence setup 0.8.
  // sanity: capacitor/contactor replacement $110–400
  { itemId: "ac-capacitor-contactor", trade: "hvac", description: "AC capacitor or contactor replacement", unit: "each", soc: HVAC_TECH, laborHours: b(0.15, 0.25, 0.4), materials: b(12, 28, 65), setup: { hours: b(0.9, 1.5, 2.6), materials: b(25, 55, 120) } },
  // Two different jobs share this phrasing — a top-up vs. finding and fixing the
  // leak — which is why the band is deliberately wide rather than averaged.
  // sanity: refrigerant leak repair & recharge $200–1,600
  { itemId: "refrigerant-recharge", trade: "hvac", description: "Refrigerant leak repair and recharge", unit: "project", soc: HVAC_TECH, laborHours: b(1.3, 3, 6.5), materials: b(90, 320, 1050) },
  // sanity: blower motor replacement $300–1,500
  { itemId: "blower-motor-replacement", trade: "hvac", description: "Furnace/air-handler blower motor replacement", unit: "each", soc: HVAC_TECH, laborHours: b(1.4, 2.4, 4), materials: b(150, 420, 1000), setup: { hours: b(0.6, 1, 1.8), materials: b(30, 70, 160) } },
  // sanity: condensate drain clearing / AC water leak $75–250
  { itemId: "condensate-drain-clearing", trade: "hvac", description: "Condensate drain clearing (AC leaking water)", unit: "project", soc: HVAC_TECH, laborHours: b(0.9, 1.5, 2.5), materials: b(15, 35, 80) },
  // sanity: furnace ignitor / flame sensor replacement $100–425
  { itemId: "furnace-ignitor-sensor", trade: "hvac", description: "Furnace ignitor or flame sensor replacement", unit: "each", soc: HVAC_TECH, laborHours: b(0.15, 0.3, 0.5), materials: b(12, 30, 75), setup: { hours: b(0.85, 1.6, 2.8), materials: b(22, 55, 130) } },
  // The existing thermostat item is a SMART install incl. the unit; a repair or
  // a plain non-smart swap is its own, cheaper job.
  // sanity: thermostat repair / non-smart replacement $85–350
  { itemId: "thermostat-repair-basic", trade: "hvac", description: "Thermostat repair or basic (non-smart) replacement", unit: "each", soc: HVAC_TECH, laborHours: b(0.25, 0.45, 0.75), materials: b(20, 50, 120), setup: { hours: b(0.6, 1.1, 1.9), materials: b(18, 40, 95) } },
  // sanity: evaporator coil replacement $600–3,000
  { itemId: "evaporator-coil-replacement", trade: "hvac", description: "Evaporator coil replacement", unit: "each", soc: HVAC_TECH, laborHours: b(2.4, 4.2, 7), materials: b(280, 780, 1900), setup: { hours: b(1.2, 2, 3.4), materials: b(60, 140, 320) } },
  // Split out of the generic repair entry: a tune-up is a scheduled maintenance
  // visit, not a fault call, and it is priced as one.
  // sanity: HVAC tune-up / seasonal maintenance $75–300
  { itemId: "hvac-tune-up", trade: "hvac", description: "HVAC tune-up / seasonal maintenance visit", unit: "project", soc: HVAC_TECH, laborHours: b(0.9, 1.6, 2.6), materials: b(10, 30, 75) },

  // --- paint -----------------------------------------------------------
  // Per sq ft of room FLOOR area (matches the taxonomy's 250 sq ft room
  // default): walls + trim, two coats. sanity: $300–800 per average room
  { itemId: "paint-interior-labor", trade: "paint", description: "Interior painting, walls + trim, per sq ft of floor area", unit: "sq ft", soc: PAINTER, laborHours: b(0.0112, 0.0168, 0.0245), materials: b(0.175, 0.315, 0.56), setup: { hours: b(1.2, 1.8, 2.625), materials: b(18.75, 33.75, 60) } },
  // Per sq ft of paintable siding. sanity: 1,500 sq ft house $2,000–5,000
  { itemId: "paint-exterior-labor", trade: "paint", description: "Exterior painting, per sq ft of siding", unit: "sq ft", soc: PAINTER, laborHours: b(0.012, 0.02, 0.032), materials: b(0.32, 0.56, 0.96), setup: { hours: b(4.5, 7.5, 12), materials: b(120, 210, 360) } },
  // sanity: kitchen cabinet spray-refinish $1,500–4,000 (~25 LF)
  { itemId: "cabinet-painting-spray", trade: "paint", description: "Cabinet spray painting, per linear foot of cabinetry", unit: "linear foot", soc: PAINTER, laborHours: b(0.7, 1.05, 1.75), materials: b(5.6, 10.5, 17.5), setup: { hours: b(6, 9, 15), materials: b(48, 90, 150) } },
  // Painting REPAIRS and prep work, added 2026-07-23. The category priced whole
  // repaints only, so the small jobs people actually call a painter for — a
  // ceiling stain after a leak, a patched hole, a wall to pressure wash —
  // classified to a per-sq-ft repaint and quoted a room.
  //
  // Bands: the first three from docs/pricing-research/anchors-verified.json,
  // the last three from Angi/HomeGuide/HomeAdvisor/Fixr 2026.
  //
  // Setup dominates the spot repairs: masking, drop cloths, mixing to match the
  // existing colour and coming back for a second coat cost the same whether the
  // patch is one hole or three.
  // sanity: ceiling water stain repair + touch-up $150–600 per spot
  { itemId: "ceiling-stain-repair", trade: "paint", description: "Water stain / ceiling spot repair, stain-blocking primer and blend", unit: "each", soc: PAINTER, laborHours: b(0.35, 0.6, 1), materials: b(12, 28, 60), setup: { hours: b(1.1, 2, 3.4), materials: b(28, 60, 130) } },
  // sanity: drywall patch and paint $75–250 per patch
  { itemId: "drywall-patch-paint", trade: "paint", description: "Drywall patch and paint (hole, nail pop, crack)", unit: "each", soc: PAINTER, laborHours: b(0.3, 0.5, 0.85), materials: b(8, 18, 40), setup: { hours: b(0.7, 1.2, 2), materials: b(15, 32, 70) } },
  // Priced per sq ft of surface washed. sanity: $0.10–0.80/sq ft
  { itemId: "pressure-washing", trade: "paint", description: "Pressure washing (house, deck, driveway)", unit: "sq ft", soc: PAINTER, laborHours: b(0.0018, 0.0038, 0.0075), materials: b(0.01, 0.02, 0.05), setup: { hours: b(0.8, 1.5, 2.6), materials: b(15, 35, 75) } },
  // Removal only — a new texture or a skim coat is extra, and ASBESTOS testing
  // is a separate trade entirely (pre-1980 ceilings run $5–20/sq ft more, which
  // this deliberately does not model rather than guessing at it).
  // sanity: popcorn ceiling removal $1–6 per sq ft
  { itemId: "popcorn-ceiling-removal", trade: "paint", description: "Popcorn ceiling removal (no asbestos), scrape and finish", unit: "sq ft", soc: PAINTER, laborHours: b(0.012, 0.022, 0.04), materials: b(0.15, 0.35, 0.8), setup: { hours: b(1.5, 2.6, 4.4), materials: b(30, 65, 140) } },
  // sanity: wallpaper removal ~$535 for a 12x12 room (~144 sq ft → $2–5/sq ft)
  { itemId: "wallpaper-removal", trade: "paint", description: "Wallpaper removal and wall prep", unit: "sq ft", soc: PAINTER, laborHours: b(0.016, 0.028, 0.048), materials: b(0.09, 0.2, 0.45), setup: { hours: b(1.4, 2.5, 4.2), materials: b(25, 55, 120) } },
  // sanity: trim / baseboard painting $0.50–3 per linear foot
  { itemId: "trim-painting", trade: "paint", description: "Trim, baseboard and crown molding painting", unit: "linear foot", soc: PAINTER, laborHours: b(0.008, 0.016, 0.028), materials: b(0.08, 0.18, 0.35), setup: { hours: b(1, 1.8, 3), materials: b(20, 42, 90) } },

  // --- deck / framing / cabinetry (carpentry trades) ---------------------
  // sanity: pressure-treated deck $25–60 per sq ft built
  { itemId: "pressure-treated-installed", trade: "deck", description: "Pressure-treated deck, framed + decked + rails", unit: "sq ft", soc: CARPENTER, laborHours: b(0.2125, 0.2975, 0.425), materials: b(6.8, 11.9, 18.7), setup: { hours: b(11.25, 15.75, 22.5), materials: b(360, 630, 990) } },
  // Deck REPAIR, added 2026-07-22. The trade had exactly one item — build a
  // whole deck — so "fix deck, replace some boards" priced a new 300 sq ft
  // deck at $14.4k, more than a full roof replacement, and no answer the
  // clarifying chat collected could move it. Repair is its own job, not a
  // fraction of construction: the framing stays, the work is selective
  // demo, sourcing stock that matches a weathered deck, and fastening into
  // existing joists.
  // sanity: $35–110 per board replaced by a pro (a 20-board job $800–2,500)
  { itemId: "deck-board-replacement", trade: "deck", description: "Replace individual deck boards on existing framing", unit: "each", soc: CARPENTER, laborHours: b(0.25, 0.4, 0.7), materials: b(12, 22, 45), setup: { hours: b(1.5, 3, 5), materials: b(40, 100, 220) } },
  // sanity: sand + re-stain/seal a deck $2–5 per sq ft
  { itemId: "deck-refinish", trade: "deck", description: "Sand and re-stain/seal an existing deck", unit: "sq ft", soc: CARPENTER, laborHours: b(0.012, 0.02, 0.03), materials: b(0.4, 0.7, 1.2), setup: { hours: b(2, 3.5, 6), materials: b(60, 130, 260) } },
  // Railings — their own job, and the one "baby proof the deck" actually means
  // (closing baluster gaps to the 4-inch code max, or adding mesh/panels).
  // sanity: $30–100 per linear foot of railing installed
  { itemId: "deck-railing", trade: "deck", description: "Deck railing — install, replace, or close baluster gaps", unit: "linear foot", soc: CARPENTER, laborHours: b(0.25, 0.4, 0.65), materials: b(14, 28, 55), setup: { hours: b(1, 2, 4), materials: b(30, 70, 160) } },
  // Structural rot/joist/post/rail work — quoted as a visit, not by area.
  // sanity: deck repair $500–3,000
  { itemId: "deck-structural-repair", trade: "deck", description: "Deck structural repair — joists, posts, rails, rot", unit: "project", soc: CARPENTER, laborHours: b(6, 14, 30), materials: b(120, 380, 900) },
  // Labor + sundries only — top and faucet come in via JOB_COMPONENTS,
  // mirroring the EPCI item this id was scoped to. sanity: $150–500 set-only
  // CARPENTRY repairs, added 2026-07-23. Bands: Angi / HomeGuide / Fixr /
  // HomeAdvisor 2026. Cabinet door repair is deliberately ABSENT — no source
  // published a band for it, and inventing one to fill the gap is exactly the
  // failure mode this engine is built to avoid.
  // sanity: fence repair $304–948 typical, ~$30 per linear foot
  { itemId: "fence-repair", trade: "framing", description: "Fence repair — posts, pickets, rails, leaning sections", unit: "linear foot", soc: CARPENTER, laborHours: b(0.16, 0.28, 0.45), materials: b(6, 13, 26), setup: { hours: b(1.1, 2, 3.4), materials: b(25, 55, 120) } },
  // sanity: exterior wood rot repair $100–500 localized (trim, sill, siding)
  { itemId: "wood-rot-repair", trade: "framing", description: "Exterior wood rot repair — trim, sill, siding, fascia", unit: "project", soc: CARPENTER, laborHours: b(1.3, 2.8, 5.5), materials: b(30, 90, 240) },
  // sanity: trim / baseboard replacement $0.50–6 per linear foot
  { itemId: "trim-carpentry", trade: "framing", description: "Baseboard, casing and trim replacement (carpentry)", unit: "linear foot", soc: CARPENTER, laborHours: b(0.02, 0.04, 0.075), materials: b(1.1, 2.2, 4.2), setup: { hours: b(0.8, 1.5, 2.6), materials: b(18, 40, 90) } },
  { itemId: "bathroom-vanity-installation", trade: "cabinetry", description: "Set vanity cabinet, attach hardware (top/plumbing separate)", unit: "each", soc: CARPENTER, laborHours: b(2, 3, 5), materials: b(30, 60, 120) },
  // sanity: stock cabinets installed $200–500 per LF
  { itemId: "stock-cabinets-installed", trade: "cabinetry", description: "Stock cabinets, supplied + installed", unit: "linear foot", soc: CARPENTER, laborHours: b(0.8, 1.2, 2), materials: b(64, 120, 240), setup: { hours: b(3, 4.5, 7.5), materials: b(240, 450, 900) } },
  // sanity: non-bearing interior wall framing $20–60 per LF
  { itemId: "wall-framing", trade: "framing", description: "Wall framing, per linear foot", unit: "linear foot", soc: CARPENTER, laborHours: b(0.2625, 0.45, 0.675), materials: b(3, 6, 10.5), setup: { hours: b(1.75, 3, 4.5), materials: b(20, 40, 70) } },
  // carpentry.general fallback — intentionally vague, always low confidence
  { itemId: "framing-labor-rate", trade: "framing", description: "General carpentry, per sq ft of project area", unit: "sq ft", soc: CARPENTER, laborHours: b(0.08, 0.15, 0.25), materials: b(1, 3, 8) },

  // --- roofing ---------------------------------------------------------
  // sanity: architectural shingles $4.50–8 per sq ft installed (tear-off incl.)
  { itemId: "architectural-installed", trade: "roofing", description: "Architectural shingles, tear-off + install", unit: "sq ft", soc: ROOFER, laborHours: b(0.0213, 0.0298, 0.0425), materials: b(1.7, 2.55, 3.825), setup: { hours: b(6.375, 8.925, 12.75), materials: b(510, 765, 1147.5) } },
  // sanity: standing-seam metal $8–16 per sq ft
  { itemId: "metal-roofing-installed", trade: "roofing", description: "Metal roofing, tear-off + install", unit: "sq ft", soc: ROOFER, laborHours: b(0.034, 0.051, 0.0765), materials: b(3.825, 5.95, 9.35), setup: { hours: b(10.2, 15.3, 22.95), materials: b(1147.5, 1785, 2805) } },
  // Whole-project band for unknown size/material — wide by design.
  // sanity: full replacement $6,000–18,000 (~1,700 sq ft equivalent)
  { itemId: "roof-replacement-total", trade: "roofing", description: "Full roof replacement, size/material unknown", unit: "project", soc: ROOFER, laborHours: b(40, 60, 90), materials: b(3500, 5500, 9000) },
  // Small-job overhead baked into hours. sanity: patch repair $300–1,200
  { itemId: "roof-repair-patch", trade: "roofing", description: "Localized roof repair, per sq ft of patch", unit: "sq ft", soc: ROOFER, laborHours: b(0.033, 0.055, 0.088), materials: b(0.825, 1.65, 3.3), setup: { hours: b(1.35, 2.25, 3.6), materials: b(33.75, 67.5, 135) } },
  // sanity: seamless aluminum gutters $6–14 per LF
  // ROOFING repairs and maintenance, added 2026-07-23. The category modelled
  // whole-roof installs plus one per-sq-ft patch, so the routine calls priced
  // absurdly: "gutter cleaning" quoted a full gutter INSTALL at $1,453 against
  // a real ~$175, and "missing shingles" quoted a $8,598 reroof against ~$300.
  // Bands: HomeGuide / Angi / Fixr 2026.
  //
  // All per-project: a roofer prices these as a visit with a ladder and a
  // couple of hours, not by area.
  // sanity: gutter cleaning $100–250
  { itemId: "gutter-cleaning", trade: "roofing", description: "Gutter cleaning and downspout flush", unit: "project", soc: ROOFER, laborHours: b(1.1, 1.8, 2.9), materials: b(0, 8, 25) },
  // sanity: gutter repair $200–600 (seams, sagging, downspouts)
  { itemId: "gutter-repair", trade: "roofing", description: "Gutter repair — seams, sagging sections, downspouts", unit: "project", soc: ROOFER, laborHours: b(1.4, 2.6, 4.4), materials: b(35, 95, 230) },
  // sanity: missing/damaged shingle replacement $150–450
  { itemId: "shingle-repair", trade: "roofing", description: "Replace missing or damaged shingles", unit: "project", soc: ROOFER, laborHours: b(1.1, 2, 3.4), materials: b(25, 70, 175) },
  // sanity: flashing repair $200–500 (minor; full replacement runs to $1,500+)
  { itemId: "flashing-repair", trade: "roofing", description: "Roof flashing repair — chimney, wall or step flashing", unit: "project", soc: ROOFER, laborHours: b(1.5, 2.7, 4.2), materials: b(40, 105, 230) },
  // sanity: roof inspection $100–400
  { itemId: "roof-inspection", trade: "roofing", description: "Roof inspection / condition report", unit: "project", soc: ROOFER, laborHours: b(1, 1.7, 3), materials: b(0, 10, 30) },
  { itemId: "gutter-install-aluminum", trade: "roofing", description: "Seamless aluminum gutters", unit: "linear foot", soc: ROOFER, laborHours: b(0.04, 0.064, 0.096), materials: b(2.4, 4, 6.4), setup: { hours: b(1.5, 2.4, 3.6), materials: b(90, 150, 240) } },

  // --- flooring ---------------------------------------------------------
  // sanity: solid hardwood $8–17 per sq ft installed
  { itemId: "hardwood-installed", trade: "flooring", description: "Solid hardwood, supplied + installed", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.0288, 0.0432, 0.0648), materials: b(2.88, 5.04, 7.92), setup: { hours: b(2.24, 3.36, 5.04), materials: b(224, 392, 616) } },
  // sanity: laminate $3–8 per sq ft installed
  { itemId: "laminate-installed", trade: "flooring", description: "Laminate flooring, supplied + installed", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.0175, 0.0245, 0.035), materials: b(1.05, 2.1, 3.5), setup: { hours: b(1.5, 2.1, 3), materials: b(90, 180, 300) } },
  // sanity: luxury vinyl plank $4–9 per sq ft installed
  { itemId: "lvp-installed", trade: "flooring", description: "Luxury vinyl plank, supplied + installed", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.0175, 0.0245, 0.035), materials: b(1.4, 2.45, 4.2), setup: { hours: b(1.5, 2.1, 3), materials: b(120, 210, 360) } },
  // sanity: carpet incl. pad $3.50–8 per sq ft installed
  { itemId: "carpet-installed", trade: "flooring", description: "Carpet + pad, supplied + installed", unit: "sq ft", soc: CARPET_INSTALLER, laborHours: b(0.0105, 0.0175, 0.028), materials: b(1.4, 2.8, 4.55), setup: { hours: b(0.9, 1.5, 2.4), materials: b(120, 240, 390) } },
  // sanity: ceramic/porcelain tile $10–25 per sq ft installed
  // Per-unit bands pulled down to the MARGINAL rate and the job's fixed cost
  // moved into `setup` (2026-07-22): tear-out and haul-away of the old floor,
  // substrate prep and waterproofing, layout, thresholds and edge trim, and the
  // cure day nobody bills below. At the 150 sq ft reference this still totals
  // the same $10-25/sq ft anchor, but a 40 sq ft bathroom no longer computes to
  // $585 the way linear-to-zero scaling made it.
  { itemId: "tile-installed", trade: "flooring", description: "Ceramic/porcelain tile, supplied + installed", unit: "sq ft", soc: TILE_SETTER, laborHours: b(0.055, 0.085, 0.13), materials: b(2.2, 4.4, 8), setup: { hours: b(3, 6, 10), materials: b(120, 260, 560) } },
  // 47-2043 is suppressed in many states — falls back to national wages.
  // sanity: sand + refinish $3–8 per sq ft
  { itemId: "hardwood-refinishing", trade: "flooring", description: "Hardwood sand + refinish", unit: "sq ft", soc: FLOOR_SANDER, laborHours: b(0.0195, 0.0292, 0.0455), materials: b(0.52, 0.975, 1.625), setup: { hours: b(2.1, 3.15, 4.9), materials: b(56, 105, 175) } },
  // SCOPE_ADD_ONS — priced per sq ft of the base job's area
  // sanity: flooring tear-out + disposal $1–3 per sq ft
  // FLOORING repairs, added 2026-07-23. Flooring modelled whole-room installs
  // and refinishing, so a single cracked tile or a squeak priced as a new
  // floor. Bands: HomeGuide / Angi / Fixr / HomeAdvisor 2026.
  // Per-project, because these are a visit and a small area, not a room.
  // sanity: cracked/broken tile replacement $130–500
  { itemId: "tile-repair", trade: "flooring", description: "Replace cracked or broken tiles", unit: "project", soc: TILE_SETTER, laborHours: b(1.2, 2.2, 3.8), materials: b(25, 70, 175) },
  // sanity: grout repair/regrout $50–1,200, avg ~$350
  { itemId: "grout-repair", trade: "flooring", description: "Grout repair, regrouting and sealing", unit: "project", soc: TILE_SETTER, laborHours: b(1, 2.6, 6), materials: b(15, 55, 170) },
  // sanity: minor carpet repair / re-stretch $130–290
  { itemId: "carpet-repair", trade: "flooring", description: "Carpet re-stretching, patching or seam repair", unit: "project", soc: CARPET_INSTALLER, laborHours: b(1.4, 2.4, 3.8), materials: b(10, 35, 90) },
  // sanity: squeaky floor repair $200–1,000
  { itemId: "squeaky-floor-repair", trade: "flooring", description: "Squeaky floor repair (fastening, shims, subfloor)", unit: "project", soc: FLOOR_LAYER, laborHours: b(1.8, 4, 9), materials: b(20, 65, 190) },
  // sanity: hardwood spot repair $25–100 per scratch, $500–1,500 typical job
  { itemId: "hardwood-spot-repair", trade: "flooring", description: "Hardwood spot repair — scratches, gouges, damaged boards", unit: "project", soc: FLOOR_SANDER, laborHours: b(1.6, 4.2, 9.5), materials: b(30, 110, 320) },
  { itemId: "flooring-removal-only", trade: "flooring", description: "Old flooring removal + disposal", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.015, 0.025, 0.04), materials: b(0.2, 0.4, 0.8) },
  // sanity: subfloor repair $2–6 per affected sq ft
  { itemId: "subfloor-repair", trade: "flooring", description: "Subfloor repair/replacement", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.03, 0.05, 0.08), materials: b(1, 2, 3.5) },
  // sanity: self-leveling underlayment $2–5 per sq ft
  { itemId: "floor-leveling", trade: "flooring", description: "Floor leveling compound", unit: "sq ft", soc: FLOOR_LAYER, laborHours: b(0.02, 0.035, 0.06), materials: b(1, 2, 3.5) },

  // --- windows ---------------------------------------------------------
  // Band is for a full-unit INSERT (frame stays). Glass-only and full-frame
  // tear-out are reached via windowScopeScale off this reference, not separate
  // rows. sanity: vinyl insert $500–1,300 installed
  { itemId: "vinyl-window-replacement", trade: "windows", description: "Vinyl replacement window, insert", unit: "each", soc: CARPENTER, laborHours: b(1.5, 2.25, 3.375), materials: b(225, 405, 712.5), setup: { hours: b(0.5, 0.75, 1.125), materials: b(75, 135, 237.5) } },
  // sanity: bay/bow window $2,000–6,000 installed
  { itemId: "bay-bow-window-replacement", trade: "windows", description: "Bay/bow window replacement", unit: "each", soc: CARPENTER, laborHours: b(6.8, 10.2, 15.3), materials: b(1020, 1870, 3400), setup: { hours: b(1.2, 1.8, 2.7), materials: b(180, 330, 600) } },
  // sanity: casement window $500–1,400 installed
  { itemId: "casement-window-replacement", trade: "windows", description: "Casement window replacement", unit: "each", soc: CARPENTER, laborHours: b(1.5, 2.25, 3.375), materials: b(262.5, 450, 750), setup: { hours: b(0.5, 0.75, 1.125), materials: b(87.5, 150, 250) } },
  // Includes foundation cut + well. sanity: egress install $2,500–6,000
  { itemId: "egress-window-installation", trade: "windows", description: "Egress window, incl. cut + well", unit: "each", soc: CARPENTER, laborHours: b(10.2, 15.3, 22.1), materials: b(850, 1530, 2720), setup: { hours: b(1.8, 2.7, 3.9), materials: b(150, 270, 480) } },

  // --- doors -----------------------------------------------------------
  // sanity: french door pair $1,500–4,500 installed
  // WINDOW + DOOR repairs, added 2026-07-23. Both trades modelled whole-unit
  // replacements, so a stuck door or a cracked pane quoted a new window or a
  // new door. Bands: Angi / HomeGuide / Fixr / HomeAdvisor 2026.
  // Glass only — the sash and frame stay. Sources span single-pane ($300-650)
  // and IGU/double-pane work, with Angi putting the average pane near $200.
  // sanity: window glass / pane replacement $150–650
  { itemId: "window-glass-repair", trade: "windows", description: "Window glass or insulated pane replacement (frame stays)", unit: "each", soc: CARPENTER, laborHours: b(0.8, 1.4, 2.4), materials: b(60, 150, 380), setup: { hours: b(0.5, 0.9, 1.6), materials: b(15, 35, 80) } },
  // sanity: sticking / hard-to-operate window repair $100–500
  { itemId: "window-hardware-repair", trade: "windows", description: "Window won't open or stay up — balance, sash cord, crank", unit: "each", soc: CARPENTER, laborHours: b(0.7, 1.3, 2.3), materials: b(20, 55, 140), setup: { hours: b(0.5, 0.9, 1.5), materials: b(12, 30, 65) } },
  // sanity: door repair / adjustment $50–700, average ~$250
  { itemId: "door-adjustment", trade: "doors", description: "Sticking or sagging door — plane, shim, rehang, hardware", unit: "each", soc: CARPENTER, laborHours: b(0.7, 1.5, 3), materials: b(10, 40, 120), setup: { hours: b(0.5, 0.9, 1.6), materials: b(12, 28, 60) } },
  // sanity: garage door spring / cable repair $180–350
  { itemId: "garage-door-spring", trade: "doors", description: "Garage door spring or cable repair", unit: "project", soc: CARPENTER, laborHours: b(1.1, 1.8, 2.8), materials: b(55, 110, 210) },
  { itemId: "french-door-installation", trade: "doors", description: "French doors, supplied + installed", unit: "pair", soc: CARPENTER, laborHours: b(4, 6.4, 9.6), materials: b(960, 1760, 3200), setup: { hours: b(1, 1.6, 2.4), materials: b(240, 440, 800) } },
  // sanity: sliding patio door $1,200–3,500 installed
  { itemId: "sliding-patio-door", trade: "doors", description: "Sliding patio door, supplied + installed", unit: "each", soc: CARPENTER, laborHours: b(3, 4.5, 6.75), materials: b(750, 1275, 2250), setup: { hours: b(1, 1.5, 2.25), materials: b(250, 425, 750) } },
  // sanity: steel entry door $600–1,800 installed
  { itemId: "exterior-door-steel", trade: "doors", description: "Steel exterior door, supplied + installed", unit: "each", soc: CARPENTER, laborHours: b(2.25, 3.75, 6), materials: b(262.5, 487.5, 900), setup: { hours: b(0.75, 1.25, 2), materials: b(87.5, 162.5, 300) } },
  // sanity: hollow-core interior door $150–500 installed
  { itemId: "interior-door-hollow-core", trade: "doors", description: "Hollow-core interior door, supplied + installed", unit: "each", soc: CARPENTER, laborHours: b(1.05, 1.75, 2.8), materials: b(56, 105, 196), setup: { hours: b(0.45, 0.75, 1.2), materials: b(24, 45, 84) } },
  // Specialty installers, not carpenters — general-maintenance wage is the
  // closest OEWS fit. sanity: single garage door $700–2,200 installed
  { itemId: "garage-door-single", trade: "doors", description: "Single garage door, supplied + installed", unit: "each", soc: MAINTENANCE, laborHours: b(2.4, 3.6, 5.6), materials: b(480, 800, 1440), setup: { hours: b(0.6, 0.9, 1.4), materials: b(120, 200, 360) } },

  // --- landscaping -------------------------------------------------------
  // sanity: sod $1–2.50 per sq ft installed
  { itemId: "sod-installation", trade: "landscaping", description: "Sod, supplied + installed", unit: "sq ft", soc: LANDSCAPER, laborHours: b(0.006, 0.009, 0.015), materials: b(0.3, 0.525, 0.825), setup: { hours: b(2, 3, 5), materials: b(100, 175, 275) } },
  // Size drives the huge spread; hours are crew-hours. sanity: $300–2,000
  { itemId: "tree-removal", trade: "landscaping", description: "Tree removal, size unknown", unit: "each", soc: LANDSCAPER, laborHours: b(4.2, 9.8, 19.6), materials: b(35, 105, 280), setup: { hours: b(1.8, 4.2, 8.4), materials: b(15, 45, 120) } },
  // sanity: irrigation $600–1,700 per zone
  { itemId: "irrigation-system-per-zone", trade: "landscaping", description: "Irrigation system, per zone", unit: "each", soc: LANDSCAPER, laborHours: b(4.2, 7, 10.5), materials: b(175, 315, 560), setup: { hours: b(1.8, 3, 4.5), materials: b(75, 135, 240) } },
  // sanity: paver patio $10–30 per sq ft
  { itemId: "paver-patio-installation", trade: "landscaping", description: "Paver patio, incl. base prep", unit: "sq ft", soc: LANDSCAPER, laborHours: b(0.117, 0.195, 0.312), materials: b(3.12, 5.46, 9.36), setup: { hours: b(6.6, 11, 17.6), materials: b(176, 308, 528) } },
  // sanity: mulch delivered + spread $45–130 per cu yd
  // LANDSCAPING maintenance, added 2026-07-23. The category modelled
  // installations only - sod, patios, irrigation systems - so the recurring
  // work that is most of the trade priced as construction: "mow my lawn"
  // quoted a SOD INSTALL, "trim my tree" quoted a removal, and "sprinkler head
  // broken" quoted a whole new zone. Bands: Angi / HomeGuide / HomeAdvisor 2026.
  // sanity: lawn mowing $50–200 per visit
  { itemId: "lawn-mowing", trade: "landscaping", description: "Lawn mowing and edging, per visit", unit: "project", soc: LANDSCAPER, laborHours: b(1, 1.9, 3.4), materials: b(0, 5, 15) },
  // sanity: yard cleanup $125–400 (fall runs $200–600, spring $100–300)
  { itemId: "yard-cleanup", trade: "landscaping", description: "Yard cleanup — debris, leaves, weeding, cut-back", unit: "project", soc: LANDSCAPER, laborHours: b(2.4, 4.6, 8), materials: b(10, 40, 110) },
  // sanity: hedge/shrub trimming $185–450 (or $25–60 per 10 ft of hedge)
  { itemId: "hedge-trimming", trade: "landscaping", description: "Hedge and shrub trimming", unit: "project", soc: LANDSCAPER, laborHours: b(3.4, 6, 10), materials: b(5, 25, 70) },
  // Distinct from removal: the tree stays. sanity: $400–900 per tree
  { itemId: "tree-trimming", trade: "landscaping", description: "Tree trimming / pruning, per tree", unit: "each", soc: LANDSCAPER, laborHours: b(6, 10.5, 17), materials: b(20, 60, 150), setup: { hours: b(1.5, 2.6, 4.4), materials: b(25, 60, 140) } },
  // sanity: sprinkler head / zone repair $130–410
  { itemId: "sprinkler-repair", trade: "landscaping", description: "Sprinkler head or zone repair", unit: "project", soc: LANDSCAPER, laborHours: b(1.6, 3, 5.2), materials: b(20, 55, 140) },
  { itemId: "mulch-installation", trade: "landscaping", description: "Mulch, delivered + spread", unit: "cubic yard", soc: LANDSCAPER, laborHours: b(0.35, 0.525, 0.84), materials: b(17.5, 28, 45.5), setup: { hours: b(0.75, 1.125, 1.8), materials: b(37.5, 60, 97.5) } },

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

  // Vinyl wrap, added 2026-07-22 — "Wrap car" returned results with no price
  // line at all. It's a standard, well-published service, and wrap shops quote
  // it off a posted hourly rate plus film, which is exactly this engine's
  // shape. Priced under auto-body rather than detailing because the trade bills
  // $75-130/hr for it; auto-body's burden lands at ~$90/hr against that, while
  // detailing's vehicle-cleaner wage would compute ~$56/hr.
  //
  // Full / partial / removal are three items on purpose: the clarifying chat
  // already asks which one this is, and that answer has to move the price.
  // sanity: full wrap $2,000–6,000 (sedan $2,000–3,500, SUV/truck $3,500–6,500;
  // exotics with premium film run past $8,000 and are out of band deliberately)
  { itemId: "vehicle-wrap-full", trade: "auto-body", description: "Full vehicle vinyl wrap, colour change", unit: "each", soc: BODY_REPAIRER, laborHours: b(16, 26, 40), materials: b(700, 1000, 1800) },
  // sanity: partial/panel wrap $500–2,000 (hood, roof, accents)
  { itemId: "vehicle-wrap-partial", trade: "auto-body", description: "Partial or panel vinyl wrap (hood, roof, accents)", unit: "each", soc: BODY_REPAIRER, laborHours: b(4, 8, 14), materials: b(150, 300, 650) },
  // Age is the real driver: a wrap under 3 years peels clean, a sun-baked
  // 5-year-old one can exceed $2,000. sanity: $300–1,500
  { itemId: "vehicle-wrap-removal", trade: "auto-body", description: "Vinyl wrap removal, incl. adhesive cleanup", unit: "each", soc: BODY_REPAIRER, laborHours: b(4, 6.5, 11), materials: b(20, 50, 120) },

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
