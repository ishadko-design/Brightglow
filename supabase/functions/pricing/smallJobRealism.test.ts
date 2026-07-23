// Small jobs must not be a linear fraction of big ones.
//
// A contractor pricing 40 sq ft of bathroom tile does not charge 40/150ths of a
// 150 sq ft floor. The demo, the waterproofing, the layout, the trip, the
// cleanup and the half-day nobody bills below are all paid in full whatever the
// area. Before `setup` existed the engine scaled linearly to zero and that
// bathroom computed to $585 against a published $1,800-6,300 (reported
// 2026-07-22).
//
// calibration.test.ts cannot catch this: it scores every item at its REFERENCE
// job size, and a linear item is exactly right there — it is only wrong away
// from that size. So this file checks the shape of the curve, not the level.
//
// It is also the guard on the backfill itself. Splitting an item into marginal
// + setup must be price-neutral at the reference size; if a split is done
// wrong, calibration fails on the level and this fails on the shape.

import { assert } from "jsr:@std/assert@1";
import { computeInHouseItems } from "./inHouseEngine.ts";
import { COST_CATALOG } from "./costCatalog.ts";
import { JOB_TYPE_TAXONOMY } from "./pricingEngine.ts";

/** Units where the customer states a size, so job size genuinely varies. */
const MEASURED_UNITS = new Set(["sq ft", "linear foot", "cubic yard"]);

/** Measured items that legitimately carry no setup, and why. Anything else
 *  priced by area or length must declare one — see the coverage test below. */
const EXEMPT: Record<string, string> = {
  // SCOPE_ADD_ONS ride on a base job that already paid the mobilization.
  // Giving them their own setup bills the customer for the crew arriving twice.
  "flooring-removal-only": "scope add-on — base job carries the mobilization",
  "subfloor-repair": "scope add-on — base job carries the mobilization",
  "floor-leveling": "scope add-on — base job carries the mobilization",
  // JOB_COMPONENTS are companion items folded into another trade's job.
  "laminate-countertop-installed": "job component — installed alongside cabinetry",
  // Deliberately vague hourly/area fallbacks used when nothing else matches;
  // they carry `loose: true` in calibration for the same reason.
  "framing-labor-rate": "category-general fallback, not a real job shape",
};

const refQuantity = new Map<string, number>();
for (const e of JOB_TYPE_TAXONOMY) {
  if (!refQuantity.has(e.itemId)) refQuantity.set(e.itemId, e.defaultQuantity);
}

const nationalById = new Map(
  [...new Set(COST_CATALOG.map((e) => e.trade))]
    .flatMap((t) => computeInHouseItems(t, undefined))
    .map((i) => [i.id, i]),
);

/** All-in cost per unit for a job of `q` units. */
function perUnitAt(id: string, q: number): number | null {
  const i = nationalById.get(id);
  if (!i) return null;
  return (i.typical * q + (i.setupTypical ?? 0)) / q;
}

Deno.test("every area/length-priced item declares a fixed setup cost", () => {
  const missing: string[] = [];
  for (const e of COST_CATALOG) {
    if (!MEASURED_UNITS.has(e.unit)) continue;
    if (EXEMPT[e.itemId]) continue;
    if (!e.setup) missing.push(`${e.itemId} (${e.unit}, ${e.trade})`);
  }
  assert(
    missing.length === 0,
    `priced per unit with no fixed cost, so a small job scales to zero:\n  ${missing.join("\n  ")}`,
  );
});

Deno.test("a quarter-size job costs meaningfully more per unit", () => {
  const linear: string[] = [];
  for (const e of COST_CATALOG) {
    if (!e.setup) continue;
    const ref = refQuantity.get(e.itemId);
    // No taxonomy entry points here, so there is no reference size to halve.
    if (!ref || ref < 4) continue;
    const small = Math.max(1, Math.round(ref / 4));
    const atSmall = perUnitAt(e.itemId, small);
    const atRef = perUnitAt(e.itemId, ref);
    if (atSmall === null || atRef === null) continue;
    const uplift = atSmall / atRef - 1;
    if (uplift < 0.15) {
      linear.push(
        `${e.itemId}: ${small} ${e.unit} costs $${atSmall.toFixed(2)}/unit vs ` +
          `$${atRef.toFixed(2)} at ${ref} — only ${(uplift * 100).toFixed(0)}% more`,
      );
    }
  }
  assert(linear.length === 0, `\n  ${linear.join("\n  ")}`);
});

Deno.test("a large job costs less per unit than a small one", () => {
  const wrong: string[] = [];
  for (const e of COST_CATALOG) {
    if (!e.setup) continue;
    const ref = refQuantity.get(e.itemId);
    if (!ref || ref < 4) continue;
    const small = perUnitAt(e.itemId, Math.max(1, Math.round(ref / 4)));
    const large = perUnitAt(e.itemId, ref * 4);
    if (small === null || large === null) continue;
    // Monotonic: economies of scale never reverse.
    if (large >= small) {
      wrong.push(`${e.itemId}: $${large.toFixed(2)}/unit at 4x ref >= $${small.toFixed(2)} at 1/4 ref`);
    }
  }
  assert(wrong.length === 0, `\n  ${wrong.join("\n  ")}`);
});
