// Tests for the in-house price computation: shape parity with the EPCI
// source, regional behavior, service minimums, and an end-to-end composed
// job mirroring what index.ts does for a request.

import { assert, assertEquals, assertExists } from "jsr:@std/assert@1";
import {
  applyServiceMinimum,
  combineSizeScope,
  computeInHouseItems,
  laborOnlyEstimate,
  parseFaceAreaSqFt,
  qualityTier,
  sizeScale,
  stateCostFactor,
  windowScopeScale,
} from "./inHouseEngine.ts";
import { estimateInHouse } from "./estimatePipeline.ts";
import { CATALOG_BY_ID, COST_CATALOG } from "./costCatalog.ts";
import { STATE_WAGES } from "./wageTable.generated.ts";
import {
  calculateComposedRange,
  classifyJobType,
  detectScopeAddOns,
  resolveJobComponents,
  resolveQuantity,
  type EPCIItem,
} from "./pricingEngine.ts";

const TRADES = [...new Set(COST_CATALOG.map((e) => e.trade))];

Deno.test("every trade computes its full catalog with valid monotonic items", () => {
  for (const trade of TRADES) {
    const items = computeInHouseItems(trade, "94102");
    const expected = COST_CATALOG.filter((e) => e.trade === trade).length;
    assertEquals(items.length, expected, `item count for ${trade}`);
    for (const item of items) {
      assert(item.low > 0, `${item.id}: zero low`);
      assert(
        item.low <= item.typical && item.typical <= item.high,
        `${item.id}: non-monotonic ${item.low}/${item.typical}/${item.high}`,
      );
      // Adjusted iff CA reports the item's occupation — suppressed SOCs
      // (e.g. floor sanders) legitimately fall back to national wages.
      const soc = CATALOG_BY_ID.get(item.id)!.soc;
      assertEquals(
        item.regionallyAdjusted,
        STATE_WAGES["CA"][soc] !== undefined,
        `${item.id}: regionallyAdjusted flag wrong`,
      );
    }
  }
});

Deno.test("unknown trade returns empty, like an EPCI miss", () => {
  assertEquals(computeInHouseItems("pest-control", "94102"), []);
});

Deno.test("metro wages beat state wages: SF prices above rural CA", () => {
  const rate = (zip: string) =>
    computeInHouseItems("plumbing", zip).find((i) => i.id === "plumber-hourly")!;
  const sf = rate("94102");    // San Francisco metro
  const ruralCA = rate("96001"); // Redding area — different metro/none
  // Under state-only wages these were identical; metro resolution separates them.
  assert(sf.typical > ruralCA.typical, `SF ${sf.typical} should exceed rural CA ${ruralCA.typical}`);
});

Deno.test("rural zip falls back to state wages, still regionally adjusted", () => {
  const items = computeInHouseItems("plumbing", "59000"); // MT rural, no metro
  assert(items.length > 0);
  // No metro row, but MT state wages exist → still flagged regional.
  assert(items.every((i) => i.regionallyAdjusted));
});

Deno.test("expensive states price above cheap states on labor-heavy work", () => {
  const rate = (zip: string) =>
    computeInHouseItems("plumbing", zip).find((i) => i.id === "plumber-hourly")!;
  const ca = rate("94102"); // CA
  const ms = rate("39201"); // MS
  assert(ca.typical > ms.typical * 1.15, `CA ${ca.typical} vs MS ${ms.typical}: spread too flat`);
});

Deno.test("materials-dominated jobs still show a visible regional spread", () => {
  const heater = (zip: string) =>
    computeInHouseItems("plumbing", zip).find((i) => i.id === "water-heater-install")!;
  const ca = heater("94102");
  const ms = heater("39201");
  // Labor alone gave ~5%; the materials passthrough should lift CA-vs-MS
  // to a visible gap without inventing a 50% one.
  assert(ca.typical > ms.typical * 1.05, `CA ${ca.typical} vs MS ${ms.typical}`);
  assert(ca.typical < ms.typical * 1.5, `CA ${ca.typical} vs MS ${ms.typical}: overcorrected`);
});

Deno.test("unroutable zips fall back to national wages, flagged unadjusted", () => {
  for (const zip of ["09001", "96201", undefined]) { // APO Europe, APO Pacific, none
    const items = computeInHouseItems("electrical", zip);
    assert(items.length > 0);
    assert(items.every((i) => !i.regionallyAdjusted), `zip ${zip} should be national`);
  }
});

Deno.test("stateCostFactor is clamped and centered", () => {
  assert(stateCostFactor(null) === 1);
  assert(stateCostFactor("ZZ") === 1);
  for (const state of ["CA", "MS", "NY", "TX", "OH"]) {
    const f = stateCostFactor(state);
    assert(f >= 0.8 && f <= 1.4, `${state} factor ${f} out of clamp`);
  }
  assert(stateCostFactor("CA") > 1.05, "CA should read as an expensive state");
  assert(stateCostFactor("MS") < 0.95, "MS should read as a cheap state");
});

Deno.test("service minimum floors a one-outlet job but not real jobs", () => {
  const floored = applyServiceMinimum(
    { all_in_low: 36, all_in_typical: 92, all_in_high: 258 },
    "electrical",
  );
  assertEquals(floored.all_in_low, 150);
  assertEquals(floored.all_in_typical, 150);
  assertEquals(floored.all_in_high, 258);

  const untouched = applyServiceMinimum(
    { all_in_low: 1200, all_in_typical: 2100, all_in_high: 3800 },
    "electrical",
  );
  assertEquals(untouched.all_in_low, 1200);
});

Deno.test("stated dimensions size the unit: 72x80 slider beats a standard window", () => {
  const std = computeInHouseItems("windows", "94102", 1, null)
    .find((i) => i.id === "vinyl-window-replacement")!;
  const big = sizeScale("vinyl-window-replacement", "sliding 72x80");
  assert(big, "72x80 should parse to a size scale");
  const sized = computeInHouseItems("windows", "94102", 1, big)
    .find((i) => i.id === "vinyl-window-replacement")!;
  // 40 sq ft vs a 10 sq ft reference — materially more, but sublinear (never 4x).
  assert(sized.typical > std.typical * 1.5, "a 4x-area window must price well above standard");
  assert(sized.typical < std.typical * 4, "size scaling must stay sublinear");
});

Deno.test("scope is the big lever: glass-only << insert << full-frame", () => {
  const item = (sizing: ReturnType<typeof combineSizeScope>) =>
    computeInHouseItems("windows", "94102", 1, sizing)
      .find((i) => i.id === "vinyl-window-replacement")!;

  const insert = item(null); // unmarked "Replace window" — the standard insert
  const glass = item(combineSizeScope(
    "vinyl-window-replacement",
    null,
    windowScopeScale("vinyl-window-replacement", "just replace the foggy glass"),
  ));
  const full = item(combineSizeScope(
    "vinyl-window-replacement",
    null,
    windowScopeScale("vinyl-window-replacement", "full-frame replacement, tear out to the rough opening"),
  ));

  assert(glass.typical < insert.typical * 0.75, `glass-only ${glass.typical} should sit well below insert ${insert.typical}`);
  assert(full.typical > insert.typical * 1.5, `full-frame ${full.typical} should sit well above insert ${insert.typical}`);
});

Deno.test("windowScopeScale only fires for openings, and reads real phrasings", () => {
  assertEquals(windowScopeScale("fixture-install", "replace the glass"), null, "non-opening item unaffected");
  assertEquals(windowScopeScale("vinyl-window-replacement", "replace the double-hung window")?.scope, undefined, "plain insert = no scope");
  assertEquals(windowScopeScale("vinyl-window-replacement", "broken pane, just the glass")?.scope, "glass only");
  assertEquals(windowScopeScale("vinyl-window-replacement", "failed seal, foggy window")?.scope, "glass only");
  assertEquals(windowScopeScale("sliding-patio-door", "new construction, full frame")?.scope, "full-frame replacement");
});

Deno.test("size and scope compose: a big full-frame window beats either alone", () => {
  const both = combineSizeScope(
    "vinyl-window-replacement",
    sizeScale("vinyl-window-replacement", "72x80"),
    windowScopeScale("vinyl-window-replacement", "full-frame replacement"),
  )!;
  const sizeOnly = sizeScale("vinyl-window-replacement", "72x80")!;
  assert(both.materials > sizeOnly.materials, "scope must stack on top of size");
  assert(both.labor > sizeOnly.labor, "scope must stack on top of size (labor)");
});

Deno.test("parseFaceAreaSqFt reads real phrasings, ignores non-sizes", () => {
  assertEquals(parseFaceAreaSqFt("Replace windows 2, sliding, 72x80"), 40);
  assertEquals(parseFaceAreaSqFt("6ft x 6ft slider"), 36);
  assertEquals(parseFaceAreaSqFt("replace kitchen sink"), null);
});

Deno.test("a size is never mistaken for a count", () => {
  const window = classifyJobType("Windows & Doors", "replace window 72x80")!;
  // "72x80" is a dimension — must not price 72 windows.
  assertEquals(resolveQuantity(window, "replace window 72x80").quantity, 1);
});

Deno.test("count trailing the noun is read: 'windows 2' = 2", () => {
  const window = classifyJobType("Windows & Doors", "Replace windows 2, sliding, 72x80")!;
  assertEquals(resolveQuantity(window, "Replace windows 2, sliding, 72x80").quantity, 2);
});

Deno.test("TV mounting is a real job, not a general-bucket guess", () => {
  // Regression: "install tv" had no item and landed on whichever category
  // general bucket the classifier picked — $220 (2 electrician hours) one run,
  // $3,476 (200 sq ft of carpentry) the next, for the same request.
  for (const desc of ["Install tv", "mount a tv on the wall", "hang tv"]) {
    const e = classifyJobType("", desc);
    assert(e, `"${desc}" should classify`);
    assertEquals(e.job_type, "electrical.tv_mount", `"${desc}" job type`);
    assert(e.keywords.length > 0, "must not be a category-general fallback");
  }
  const item = computeInHouseItems("electrical", "94102")
    .find((i) => i.id === "tv-mount-install")!;
  // A wall mount is a few hundred dollars, not a few thousand.
  assert(item.typical > 150 && item.typical < 700, `implausible TV mount ${item.typical}`);
});

Deno.test("TV add-ons price the real cost drivers", () => {
  const entry = classifyJobType("", "mount tv above fireplace with wires hidden")!;
  const labels = detectScopeAddOns(entry, "mount tv above fireplace with wires hidden")
    .map((a) => a.label).sort();
  assertEquals(labels, ["cord concealment", "masonry mounting"]);
  // Plain drywall mount picks up neither.
  assertEquals(detectScopeAddOns(entry, "mount tv on wall").length, 0);
});

Deno.test("labor-only estimates bill at market service rates", () => {
  // Measured 2026-07-16: at the 2.2 project burden these came out at $77/hr,
  // below the $75-200 market floor. SERVICE_CALL_BURDEN should put them
  // mid-market — this test is the guard that regression can't come back.
  for (const trade of ["plumbing", "electrical", "hvac"]) {
    const nat = laborOnlyEstimate(trade, undefined)!;
    assert(nat, `${trade} should have a labor-only estimate`);
    assert(
      nat.hourlyTypical > 80 && nat.hourlyTypical < 160,
      `${trade} national billed rate ${nat.hourlyTypical}/hr outside market range`,
    );
  }
  // Metro wages still drive it: SF above national.
  const sf = laborOnlyEstimate("plumbing", "94102")!;
  const nat = laborOnlyEstimate("plumbing", undefined)!;
  assert(sf.hourlyTypical > nat.hourlyTypical, "SF labor should exceed national");
});

Deno.test("labor-only is null for a trade with no catalog presence", () => {
  assertEquals(laborOnlyEstimate("underwater-basket-weaving", "94102"), null);
});

Deno.test("quality tier scales materials, not labor", () => {
  const base = computeInHouseItems("plumbing", "94102", 1).find((i) => i.id === "fixture-install")!;
  const premium = computeInHouseItems("plumbing", "94102", 1.4).find((i) => i.id === "fixture-install")!;
  const budget = computeInHouseItems("plumbing", "94102", 0.75).find((i) => i.id === "fixture-install")!;
  // Materials-heavy fixture: premium clearly higher, budget clearly lower.
  assert(premium.typical > base.typical, "premium should raise a fixture");
  assert(budget.typical < base.typical, "budget should lower a fixture");
  // Labor-only hourly item: tier barely moves it (materials are ~$10).
  const laborBase = computeInHouseItems("plumbing", "94102", 1).find((i) => i.id === "plumber-hourly")!;
  const laborPrem = computeInHouseItems("plumbing", "94102", 1.4).find((i) => i.id === "plumber-hourly")!;
  assert(laborPrem.typical - laborBase.typical < 5, "tier must not inflate labor");
});

Deno.test("qualityTier reads grade words", () => {
  assertEquals(qualityTier("install high-end faucet").tier, "premium");
  assertEquals(qualityTier("luxury kitchen remodel").tier, "premium");
  assertEquals(qualityTier("builder-grade cabinets").tier, "budget");
  assertEquals(qualityTier("cheapest option please").tier, "budget");
  assertEquals(qualityTier("replace kitchen sink").tier, null);
});

Deno.test("end-to-end: vanity job composes top + faucet across trades", () => {
  const description = "replace 36 inch bathroom vanity";
  const entry = classifyJobType("Carpentry", description);
  assertExists(entry);
  assertEquals(entry!.job_type, "carpentry.vanity");

  const { quantity } = resolveQuantity(entry!, description);
  const componentTrades = [...new Set(resolveJobComponents(entry!.job_type, description).map((c) => c.trade))];
  const itemsByTrade: Record<string, EPCIItem[]> = {};
  for (const trade of [entry!.trade, ...componentTrades]) {
    itemsByTrade[trade] = computeInHouseItems(trade, "94102");
  }
  const addOns = detectScopeAddOns(entry!, description);
  const range = calculateComposedRange(itemsByTrade, entry!, quantity, description, addOns.map((a) => a.itemId));
  assertExists(range);
  assertEquals(range!.includedLabels.sort(), ["faucet install", "vanity top"]);
  // Cabinet set + top + faucet should land in real-vanity-swap territory,
  // not the $236-708 labor-only trap the EPCI item had before composition.
  assert(range!.all_in_typical > 700, `typical ${range!.all_in_typical} too low for a full vanity swap`);
  assert(range!.all_in_high < 4000, `high ${range!.all_in_high} implausible`);
});

Deno.test("a flat scope add-on is charged once, not per square foot", () => {
  // Add-ons fold into the PER-UNIT rate and scale with the job, which is right
  // for per-sq-ft add-ons and catastrophic for a fixed cost. Containment billed
  // per unit produced $31,427 for 40 sq ft of mold and $115,039 for 150 — and
  // more for a small job than the 100 sq ft reference, which is the tell.
  const priceAt = (description: string) => {
    const entry = classifyJobType("Mold & Pest Control", description)!;
    const r = estimateInHouse({
      category: "Mold & Pest Control",
      description,
      zip: "94102",
      vehicle: null,
      vertical: "home",
      entryOverride: entry,
    });
    assert(r.kind === "range", `expected a range, got ${r.kind}`);
    return r.typical;
  };
  const bare40 = priceAt("mold remediation 40 sq ft");
  const contained40 = priceAt("mold remediation 40 sq ft with full containment");
  const contained150 = priceAt("mold remediation 150 sq ft with full containment");

  // Containment costs something, but a bounded something — not 40x something.
  assert(contained40 > bare40, "containment should add cost");
  assert(
    contained40 - bare40 < 1500,
    `containment added ${Math.round(contained40 - bare40)} to a 40 sq ft job — it is being scaled per unit`,
  );
  // And the same add-on must cost the same on a bigger job.
  const bare150 = priceAt("mold remediation 150 sq ft");
  const delta40 = contained40 - bare40;
  const delta150 = contained150 - bare150;
  assert(
    Math.abs(delta40 - delta150) < 1,
    `containment cost ${Math.round(delta40)} at 40 sq ft but ${Math.round(delta150)} at 150`,
  );
});

Deno.test("short pest/mold keywords do not fire inside longer words", () => {
  // Each of these is a word that CONTAINS a Mold & Pest keyword. None of them
  // is a mold or pest job, and before the word-boundary guard "replace the
  // crown molding" priced as paintless dent repair on a car.
  for (const text of [
    "replace the crown molding",
    "install baseboard molding",
    "plant new shrubs along the fence",
    "aerate and reseed the lawn",
    "the deck has been rotting",
  ]) {
    const entry = classifyJobType("", text);
    assert(
      entry?.category !== "Mold & Pest Control",
      `"${text}" classified as ${entry?.job_type}`,
    );
    assert(entry?.job_type !== "auto.dent", `"${text}" classified as a car dent`);
  }
  // The real words still work.
  assertEquals(classifyJobType("", "ants in the kitchen")?.job_type, "pest.treatment");
  assertEquals(classifyJobType("", "moldy drywall")?.job_type, "mold.remediation");
  // A pest in something another category owns still routes to the pest.
  assertEquals(classifyJobType("", "we have termites in the deck")?.job_type, "pest.termite");
});

Deno.test("dimensions are never counts: regression for '36 inch vanity' = 36 vanities", () => {
  const vanity = classifyJobType("Carpentry", "replace 36 inch bathroom vanity")!;
  assertEquals(resolveQuantity(vanity, "replace 36 inch bathroom vanity").quantity, 1);
  assertEquals(resolveQuantity(vanity, 'replace 36" bathroom vanity').quantity, 1);
  assertEquals(resolveQuantity(vanity, "replace 2 bathroom vanities").quantity, 2);

  const window = classifyJobType("Windows & Doors", "install 3 casement windows")!;
  assertEquals(resolveQuantity(window, "install 3 casement windows").quantity, 3);
  assertEquals(resolveQuantity(window, "install 24 inch casement window").quantity, 1);
});

Deno.test("spelled-out counts are read: 'two windows' = 2", () => {
  const window = classifyJobType("Windows & Doors", "replace two windows")!;
  assertEquals(resolveQuantity(window, "replace two windows").quantity, 2);
  assertEquals(resolveQuantity(window, "replace three windows").quantity, 3);
  // A spelled number that isn't a count must not misfire as a dimension/size.
  const outlet = classifyJobType("Electrical", "install four outlets")!;
  assertEquals(resolveQuantity(outlet, "install four outlets").quantity, 4);
});

Deno.test("end-to-end: flooring add-ons raise the lvp range", () => {
  const description = "install 400 sq ft vinyl plank, remove old floor";
  const entry = classifyJobType("Flooring", description);
  assertExists(entry);
  assertEquals(entry!.job_type, "flooring.lvp");
  const { quantity } = resolveQuantity(entry!, description);
  assertEquals(quantity, 400);

  const itemsByTrade = { flooring: computeInHouseItems("flooring", "78701") };
  const addOns = detectScopeAddOns(entry!, description);
  assertEquals(addOns.map((a) => a.label), ["old floor removal"]);

  const withAddOn = calculateComposedRange(itemsByTrade, entry!, quantity, description, addOns.map((a) => a.itemId));
  const without = calculateComposedRange(itemsByTrade, entry!, quantity, description, []);
  assert(withAddOn!.all_in_typical > without!.all_in_typical, "removal add-on must raise the price");
});
