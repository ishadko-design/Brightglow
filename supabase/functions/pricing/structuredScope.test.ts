// Does the LLM classifier's STRUCTURED scope actually reach the price?
//
// detailSensitivity.test.ts proves the deterministic prose parsers move the
// number. This file proves the new authoritative path: when index.ts passes a
// JobScope (quantity / areaSqFt / tier the model read off the request), the
// engine prices THOSE dimensions over the prose regex — and, critically, a
// stated quantity flips the estimate off its silent default, so confidence
// stops lying about a number the user actually specified.
//
// Every case uses a description with NO parseable count, so the movement can
// only come from the structured scope, not the prose fallback.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { estimateInHouse, type JobScope } from "./estimatePipeline.ts";

const ZIP = "94014";

function priced(description: string, scope?: JobScope) {
  const r = estimateInHouse({ category: "Windows & Doors", description, zip: ZIP, scope });
  assert(r.kind === "range", `expected a range, got ${r.kind} for "${description}"`);
  return r;
}

// A phrasing that classifies to the vinyl-window entry but states no count.
const DESC = "replace the vinyl windows in the house";

Deno.test("structured quantity scales the price and clears the default flag", () => {
  const base = priced(DESC); // no scope -> prose finds no count -> defaults
  assert(base.isDefaulted, "no-count description should default its quantity");
  assertEquals(base.confidence, "low", "a defaulted quantity is low confidence");

  const one = priced(DESC, { quantity: 1 });
  const five = priced(DESC, { quantity: 5 });

  assert(!one.isDefaulted, "an explicit quantity is not a default");
  assertEquals(one.confidence, "med", "a stated quantity lifts confidence off low");
  assertEquals(one.quantity, 1);
  assertEquals(five.quantity, 5);
  assert(
    five.typical > one.typical * 3,
    `5 windows (${five.typical}) should far exceed 1 (${one.typical})`,
  );
});

Deno.test("structured area scales an area-referenced item", () => {
  const small = priced(DESC, { quantity: 1, areaSqFt: 10 }); // ~reference size
  const large = priced(DESC, { quantity: 1, areaSqFt: 40 }); // 4x the face area
  assert(
    large.typical > small.typical,
    `a 40 sqft window (${large.typical}) should cost more than a 10 sqft one (${small.typical})`,
  );
});

Deno.test("structured tier moves materials both ways", () => {
  const budget = priced(DESC, { quantity: 2, tier: "budget" });
  const standard = priced(DESC, { quantity: 2, tier: "standard" });
  const premium = priced(DESC, { quantity: 2, tier: "premium" });
  assert(
    budget.typical < standard.typical && standard.typical < premium.typical,
    `tier should order budget<standard<premium, got ${budget.typical} / ${standard.typical} / ${premium.typical}`,
  );
});

Deno.test("absent scope is byte-identical to the pre-scope path", () => {
  // The keyword/harness path passes no scope; it must behave exactly as before.
  const withNull = priced(DESC, undefined);
  const withEmpty = priced(DESC, {});
  assertEquals(withNull.typical, withEmpty.typical);
  assert(withEmpty.isDefaulted, "an empty scope still defers to the prose parsers");
});
