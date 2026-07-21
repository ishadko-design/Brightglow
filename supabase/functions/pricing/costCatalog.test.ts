// Guards the contract between the in-house cost catalog and everything that
// requests items by id: the taxonomy, category fallbacks, scope add-ons, and
// cross-trade job components. A missing or mismatched entry here means some
// user request silently falls through to "coming soon".

import { assert, assertEquals, assertExists } from "jsr:@std/assert@1";
import { CATALOG_BY_ID, COST_CATALOG } from "./costCatalog.ts";
import { NATIONAL_WAGES, STATE_WAGES } from "./wageTable.generated.ts";
import {
  CATEGORY_GENERAL,
  JOB_COMPONENTS,
  JOB_TYPE_TAXONOMY,
  SCOPE_ADD_ONS,
} from "./pricingEngine.ts";

Deno.test("every taxonomy itemId has a catalog entry with matching unit and trade", () => {
  const entries = [...JOB_TYPE_TAXONOMY, ...Object.values(CATEGORY_GENERAL).filter((e) => e !== null)];
  for (const entry of entries) {
    const item = CATALOG_BY_ID.get(entry.itemId);
    assertExists(item, `missing catalog entry: ${entry.itemId} (${entry.job_type})`);
    assertEquals(item.unit, entry.unit, `unit mismatch for ${entry.itemId}`);
    assertEquals(item.trade, entry.trade, `trade mismatch for ${entry.itemId}`);
  }
});

Deno.test("every scope add-on and job component itemId has a catalog entry", () => {
  for (const addOn of SCOPE_ADD_ONS) {
    assertExists(CATALOG_BY_ID.get(addOn.itemId), `missing add-on entry: ${addOn.itemId}`);
  }
  for (const components of Object.values(JOB_COMPONENTS)) {
    for (const c of components) {
      const item = CATALOG_BY_ID.get(c.itemId);
      assertExists(item, `missing component entry: ${c.itemId}`);
      assertEquals(item.trade, c.trade, `trade mismatch for component ${c.itemId}`);
    }
  }
});

Deno.test("catalog entries are internally consistent", () => {
  const seen = new Set<string>();
  for (const e of COST_CATALOG) {
    assert(!seen.has(e.itemId), `duplicate itemId: ${e.itemId}`);
    seen.add(e.itemId);
    for (const band of [e.laborHours, e.materials]) {
      assert(
        band.low <= band.typical && band.typical <= band.high,
        `non-monotonic band on ${e.itemId}`,
      );
    }
    assert(e.laborHours.low >= 0 && e.materials.low >= 0, `negative band on ${e.itemId}`);
    assert(e.laborHours.high > 0, `zero labor on ${e.itemId}`);
  }
});

Deno.test("every catalog SOC exists in the national wage table", () => {
  for (const e of COST_CATALOG) {
    assertExists(NATIONAL_WAGES[e.soc], `SOC ${e.soc} (${e.itemId}) missing from national wages`);
  }
});

Deno.test("wage table is sane: 50 states + DC, positive monotonic percentiles", () => {
  assertEquals(Object.keys(STATE_WAGES).length, 51);
  for (const [state, socs] of Object.entries(STATE_WAGES)) {
    for (const [soc, w] of Object.entries(socs)) {
      assert(w.p25 > 7 && w.p75 < 115, `implausible wage for ${state}/${soc}`);
      assert(w.p25 <= w.median && w.median <= w.p75, `non-monotonic wages for ${state}/${soc}`);
    }
  }
});
