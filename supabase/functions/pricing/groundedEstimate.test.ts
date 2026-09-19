// The grounded band's guardrail is what stands between a web-searched number
// and the user's screen. These cover the pure parse + sanity logic; the live
// web_search call can't be exercised offline.

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  buildGroundedSystemPrompt,
  canonicalJob,
  parseGroundedBand,
  saneBand,
} from "./groundedEstimate.ts";

Deno.test("canonicalJob collapses phrasing variants to one key", () => {
  // The whole point: these must all hit the same cache entry.
  const k = "kitchen:remodel";
  assertEquals(canonicalJob("kitchen remodel"), k);
  assertEquals(canonicalJob("remodel my kitchen"), k);
  assertEquals(canonicalJob("kitchen renovation"), k);
  assertEquals(canonicalJob("I want to renovate the kitchen"), k);
});

Deno.test("canonicalJob distinguishes scope and subject", () => {
  assertEquals(canonicalJob("full gut remodel of my bathroom, ~60 sq ft"), "bathroom:gut-remodel");
  assertEquals(canonicalJob("bathroom remodel"), "bathroom:remodel"); // gut != plain
  assertEquals(canonicalJob("finish my basement"), "basement:remodel");
  assertEquals(canonicalJob("build an ADU in the backyard"), "adu:addition");
});

Deno.test("canonicalJob returns null when no subject is recognized", () => {
  // Falls back to full-text keying (safe, lower hit rate) — not a wrong collapse.
  assertEquals(canonicalJob("respray the whole car"), null);
  assertEquals(canonicalJob("full engine rebuild on my Ducati"), null);
});

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

Deno.test("prompt is domain-aware (home vs auto vs moto)", () => {
  const home = buildGroundedSystemPrompt("the 94014 area (US)", "home");
  assert(home.includes("homeowner") && home.includes("contractor"));
  assert(home.includes("sq ft")); // home scope example

  const auto = buildGroundedSystemPrompt("the 94014 area (US)", "auto");
  assert(auto.includes("car or truck") && auto.includes("parts"));
  assert(!auto.includes("homeowner"));

  const moto = buildGroundedSystemPrompt("the 94014 area (US)", "moto");
  assert(moto.includes("motorcycle"));
  assert(!moto.includes("car or truck"));
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
