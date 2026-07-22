// Calibration harness — the repeatable "is the engine still accurate?" check.
//
// Each catalog item was built against a published national installed range
// (the `// sanity:` comments in costCatalog.ts). This test recomputes every
// item at national wages and flags any whose computed typical has drifted
// outside that anchor, or whose low–high band misses the anchor entirely.
// Run it after any catalog/wage/burden change:  deno test calibration.test.ts
//
// REFERENCE bands are national, expressed in each item's own unit (per sq ft,
// per each, per project…) exactly as the sanity comment states them — so the
// computed per-unit number compares directly, no quantity assumptions. Update
// a REFERENCE entry only against a real published source, never to paper over
// a bad computed number.

import { assert } from "jsr:@std/assert@1";
import { computeInHouseItems } from "./inHouseEngine.ts";
import { COST_CATALOG } from "./costCatalog.ts";
import { JOB_TYPE_TAXONOMY } from "./pricingEngine.ts";

interface Ref {
  low: number;
  high: number;
  /** Skip the strict typical-in-band assertion — the item is intentionally
   *  vague (category-general fallbacks) so only gross drift matters. */
  loose?: boolean;
  note?: string;
}

// National published installed ranges, per unit. Sources: Angi / HomeAdvisor /
// Fixr class aggregates, 2026. Converted to per-unit where the comment quoted a
// whole job (e.g. interior paint $300–800 per 250 sq ft room → $1.20–3.20/sq ft).
const REFERENCE: Record<string, Ref> = {
  // plumbing
  "water-heater-install": { low: 1000, high: 2500 },
  "tankless-water-heater-install": { low: 2500, high: 4500 },
  "fixture-install": { low: 150, high: 600 },
  "pipe-repair": { low: 150, high: 700 },
  "whole-house-repipe-pex": { low: 2.67, high: 10 },
  "sewer-line-replacement": { low: 50, high: 250 },
  "plumber-hourly": { low: 75, high: 200, loose: true },
  "faucet-install-plumbing": { low: 150, high: 450 },
  // electrical
  "panel-upgrade-200amp": { low: 1800, high: 4000 },
  "outlet-installation": { low: 100, high: 350 },
  "ceiling-fan-install": { low: 150, high: 400 },
  "ev-charger-level2": { low: 1000, high: 2500 },
  "whole-house-rewire": { low: 4, high: 10 },
  "solar-panel-install": { low: 850, high: 1550 },
  "light-fixture-install": { low: 75, high: 250 },
  "electrician-hourly": { low: 85, high: 200, loose: true },
  "tv-mount-install": { low: 200, high: 600 },
  "tv-cord-concealment": { low: 100, high: 400 },
  "tv-mount-masonry": { low: 75, high: 300 },
  // hvac
  "gas-furnace-installed": { low: 3000, high: 6500 },
  "central-ac-installed": { low: 3800, high: 7500 },
  "heat-pump-installed": { low: 4500, high: 9500 },
  "mini-split-per-zone": { low: 2000, high: 4000 },
  "thermostat-installation-smart": { low: 200, high: 500 },
  "furnace-repair": { low: 150, high: 800 },
  "hvac-labor-rate": { low: 90, high: 200, loose: true },
  // paint
  "paint-interior-labor": { low: 1.2, high: 3.2 },
  "paint-exterior-labor": { low: 1.33, high: 3.33 },
  "cabinet-painting-spray": { low: 60, high: 160 },
  // carpentry trades
  "pressure-treated-installed": { low: 25, high: 60 },
  "deck-board-replacement": { low: 35, high: 110 },
  "deck-refinish": { low: 2, high: 5 },
  "deck-structural-repair": { low: 500, high: 3000 },
  "deck-railing": { low: 30, high: 100 },
  "bathroom-vanity-installation": { low: 150, high: 500 },
  "stock-cabinets-installed": { low: 200, high: 500 },
  "wall-framing": { low: 20, high: 60 },
  "framing-labor-rate": { low: 2, high: 15, loose: true },
  // roofing
  "architectural-installed": { low: 4.5, high: 8 },
  "metal-roofing-installed": { low: 8, high: 16 },
  "roof-replacement-total": { low: 6000, high: 18000 },
  "roof-repair-patch": { low: 6, high: 24 },
  "gutter-install-aluminum": { low: 6, high: 14 },
  // flooring
  "hardwood-installed": { low: 8, high: 17 },
  "laminate-installed": { low: 3, high: 8 },
  "lvp-installed": { low: 4, high: 9 },
  "carpet-installed": { low: 3.5, high: 8 },
  "tile-installed": { low: 10, high: 25 },
  "hardwood-refinishing": { low: 3, high: 8 },
  "flooring-removal-only": { low: 1, high: 3 },
  "subfloor-repair": { low: 2, high: 6 },
  "floor-leveling": { low: 2, high: 5 },
  // windows
  "vinyl-window-replacement": { low: 450, high: 1200 },
  "bay-bow-window-replacement": { low: 2000, high: 6000 },
  "casement-window-replacement": { low: 500, high: 1400 },
  "egress-window-installation": { low: 2500, high: 6000 },
  // doors
  "french-door-installation": { low: 1500, high: 4500 },
  "sliding-patio-door": { low: 1200, high: 3500 },
  "exterior-door-steel": { low: 600, high: 1800 },
  "interior-door-hollow-core": { low: 150, high: 500 },
  "garage-door-single": { low: 700, high: 2200 },
  // landscaping
  "sod-installation": { low: 1, high: 2.5 },
  "tree-removal": { low: 300, high: 2000 },
  "irrigation-system-per-zone": { low: 600, high: 1700 },
  "paver-patio-installation": { low: 10, high: 30 },
  "mulch-installation": { low: 45, high: 130 },
  // countertops
  "laminate-countertop-installed": { low: 25, high: 70 },

  // === Auto & moto (added 2026-07-20) ===================================
  // Anchors are published national all-in (parts + labor) ranges for a common
  // mid-size sedan. Sources: RepairPal estimator, AAA, KBB, Tekmetric/AutoLeap
  // rate surveys, 2026. Same rule as the home items — move a band only against
  // a real published source.
  // auto repair
  "oil-change-synthetic": { low: 65, high: 125 },
  "brake-pads-per-axle": { low: 330, high: 390 },
  "brake-pads-rotors-per-axle": { low: 450, high: 750 },
  "battery-replacement": { low: 150, high: 450 },
  "alternator-replacement": { low: 802, high: 1073 },
  "starter-replacement": { low: 566, high: 787 },
  "water-pump-replacement": { low: 888, high: 1139 },
  // Widened to span a genuine source conflict: RepairPal $1,353–1,528 vs
  // ConsumerAffairs-class guides $600–1,200. Held-out set decides.
  "radiator-replacement": { low: 900, high: 1500 },
  "timing-belt-replacement": { low: 700, high: 1200 },
  "spark-plug-replacement": { low: 100, high: 250 },
  "ac-recharge-auto": { low: 200, high: 350 },
  "transmission-fluid-change": { low: 80, high: 250 },
  "catalytic-converter-replacement": { low: 800, high: 2500 },
  "oxygen-sensor-replacement": { low: 150, high: 300 },
  "muffler-exhaust-repair": { low: 150, high: 600 },
  "strut-shock-per-axle": { low: 450, high: 900 },
  "cv-axle-replacement": { low: 300, high: 800 },
  "fuel-pump-replacement": { low: 700, high: 1400 },
  "clutch-replacement": { low: 1000, high: 2000 },
  "auto-diagnostic-fee": { low: 75, high: 180 },
  "auto-labor-hourly": { low: 100, high: 200, loose: true },
  // tires
  "tire-replacement-per-tire": { low: 150, high: 350 },
  "tire-mount-balance-per-tire": { low: 15, high: 45 },
  "tire-rotation": { low: 20, high: 60 },
  "flat-tire-repair": { low: 15, high: 45 },
  "wheel-alignment": { low: 80, high: 200 },
  "tpms-sensor-per-wheel": { low: 50, high: 130 },
  // detailing
  "full-detail": { low: 150, high: 400 },
  "interior-detail": { low: 100, high: 250 },
  "exterior-detail-wax": { low: 75, high: 200 },
  "car-wash-basic": { low: 15, high: 40 },
  "ceramic-coating": { low: 700, high: 1850 },
  "headlight-restoration": { low: 100, high: 200 },
  "paint-correction": { low: 300, high: 1000 },
  // body & paint
  "bumper-repair-scuff": { low: 150, high: 500 },
  "bumper-replacement": { low: 800, high: 2500 },
  "pdr-dent-repair": { low: 150, high: 400 },
  "panel-respray": { low: 200, high: 1500 },
  "full-respray": { low: 1500, high: 5000 },
  "collision-panel-replacement": { low: 600, high: 2000 },
  // glass
  "windshield-replacement": { low: 250, high: 800 },
  "windshield-chip-repair": { low: 60, high: 150 },
  "adas-recalibration": { low: 150, high: 400 },
  "side-window-replacement": { low: 200, high: 500 },
  // motorcycle
  "moto-tire-replacement-per-tire": { low: 160, high: 300 },
  "moto-tire-mount-balance-per-tire": { low: 30, high: 60 },
  "moto-oil-change": { low: 40, high: 100 },
  "moto-brake-pads-per-wheel": { low: 130, high: 300 },
  "moto-chain-sprocket": { low: 150, high: 450 },
};

/** Every catalog item priced at national wages, by id, as an ALL-IN PER-UNIT
 *  rate at a reference job size — i.e. (per-unit x quantity + setup) / quantity.
 *
 *  Published per-unit figures ("$10-25 per sq ft of tile") are quoted for
 *  typical job sizes and silently include the job's setup spread across it. So
 *  once setup is split out of the per-unit rate, comparing the bare marginal
 *  rate against those anchors would flag every item as far too cheap. The
 *  reference size is the taxonomy's own defaultQuantity — what the engine
 *  actually assumes when the user states no size. */
function nationalItems(): Map<string, { low: number; typical: number; high: number }> {
  const sizeFor = new Map<string, number>();
  for (const e of JOB_TYPE_TAXONOMY) {
    if (!sizeFor.has(e.itemId)) sizeFor.set(e.itemId, e.defaultQuantity);
  }
  const trades = [...new Set(COST_CATALOG.map((e) => e.trade))];
  const out = new Map<string, { low: number; typical: number; high: number }>();
  for (const trade of trades) {
    for (const item of computeInHouseItems(trade, undefined)) {
      const q = sizeFor.get(item.id) ?? 1;
      out.set(item.id, {
        low: (item.low * q + (item.setupLow ?? 0)) / q,
        typical: (item.typical * q + (item.setupTypical ?? 0)) / q,
        high: (item.high * q + (item.setupHigh ?? 0)) / q,
      });
    }
  }
  return out;
}

Deno.test("every catalog item has a calibration reference", () => {
  const missing = COST_CATALOG.map((e) => e.itemId).filter((id) => !REFERENCE[id]);
  assert(missing.length === 0, `no REFERENCE band for: ${missing.join(", ")}`);
});

Deno.test("computed national typical sits inside its published anchor band", () => {
  const items = nationalItems();
  const drift: string[] = [];
  for (const [id, ref] of Object.entries(REFERENCE)) {
    const got = items.get(id);
    if (!got) continue; // coverage checked separately
    if (ref.loose) continue;
    // Typical must land within the anchor (a hair of slack for rounding).
    const lo = ref.low * 0.98;
    const hi = ref.high * 1.02;
    if (got.typical < lo || got.typical > hi) {
      const pct = got.typical < lo
        ? `${Math.round((1 - got.typical / ref.low) * 100)}% low`
        : `${Math.round((got.typical / ref.high - 1) * 100)}% high`;
      drift.push(
        `${id}: typical ${got.typical.toFixed(2)} outside [${ref.low}, ${ref.high}] (${pct})`,
      );
    }
  }
  assert(drift.length === 0, `\n  ${drift.join("\n  ")}`);
});

Deno.test("computed low–high band overlaps its anchor (no total miss)", () => {
  const items = nationalItems();
  const miss: string[] = [];
  for (const [id, ref] of Object.entries(REFERENCE)) {
    const got = items.get(id);
    if (!got) continue;
    if (got.high < ref.low || got.low > ref.high) {
      miss.push(`${id}: band [${got.low}, ${got.high}] misses anchor [${ref.low}, ${ref.high}]`);
    }
  }
  assert(miss.length === 0, `\n  ${miss.join("\n  ")}`);
});
