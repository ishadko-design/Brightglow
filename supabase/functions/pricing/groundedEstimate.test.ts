// The grounded band's guardrail is what stands between a web-searched number
// and the user's screen. These cover the pure parse + sanity logic; the live
// web_search call can't be exercised offline.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { parseGroundedBand, saneBand } from "./groundedEstimate.ts";

Deno.test("parseGroundedBand: clean JSON", () => {
  const b = parseGroundedBand('{"low":12000,"typical":20000,"high":32000,"basis":"gut bath, mid-grade"}');
  assertEquals(b, { low: 12000, typical: 20000, high: 32000, basis: "gut bath, mid-grade" });
});

Deno.test("parseGroundedBand: JSON wrapped in prose, last object wins", () => {
  const text =
    'Based on my search {"note":"ignore"} the estimate is:\n{"low":8000,"typical":15000,"high":25000,"basis":"remodel"}';
  const b = parseGroundedBand(text);
  assert(b);
  assertEquals(b.typical, 15000);
});

Deno.test("parseGroundedBand: missing/garbage returns null", () => {
  assertEquals(parseGroundedBand(undefined), null);
  assertEquals(parseGroundedBand("no json here"), null);
  assertEquals(parseGroundedBand('{"low":"cheap","high":5}'), null); // non-numeric
});

Deno.test("saneBand: a plausible range passes", () => {
  assert(saneBand({ low: 12000, typical: 20000, high: 32000, basis: "" }));
});

Deno.test("saneBand rejects the ways a search goes wrong", () => {
  // all-zero "insufficient data" sentinel from the prompt
  assertEquals(saneBand({ low: 0, typical: 0, high: 0, basis: "insufficient data" }), null);
  // out of order
  assertEquals(saneBand({ low: 30000, typical: 20000, high: 10000, basis: "" }), null);
  // negative
  assertEquals(saneBand({ low: -5, typical: 100, high: 200, basis: "" }), null);
  // below the $50 floor (likely a per-unit or hourly figure misread as a job)
  assertEquals(saneBand({ low: 5, typical: 20, high: 40, basis: "" }), null);
  // above a whole-home rebuild — not a job estimate
  assertEquals(saneBand({ low: 400000, typical: 600000, high: 900000, basis: "" }), null);
  // a 20x+ span is noise, not an estimate
  assertEquals(saneBand({ low: 1000, typical: 5000, high: 40000, basis: "" }), null);
  assertEquals(saneBand(null), null);
});
