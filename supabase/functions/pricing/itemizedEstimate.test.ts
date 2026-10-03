import { assertEquals } from "jsr:@std/assert@1";
import { canonicalKey, factToken, parseComponents, sumComponents } from "./itemizedEstimate.ts";

Deno.test("sumComponents: certain parts count fully; an uncertain part adds half its typical to typical and its typical (not worst case) to high", () => {
  const r = sumComponents([
    { name: "permit", low: 200, typical: 300, high: 500, certain: true },
    { name: "circuit", low: 1000, typical: 1500, high: 2200, certain: true },
    { name: "trench", low: 800, typical: 1200, high: 2000, certain: false },
  ]);
  assertEquals(r, { low: 1200, typical: 2400, high: 3900 });
});

Deno.test("sumComponents repairs an out-of-order component", () => {
  assertEquals(sumComponents([{ name: "x", low: 500, typical: 100, high: 300, certain: true }]),
    { low: 100, typical: 100, high: 500 });
});

Deno.test("parseComponents drops malformed rows", () => {
  const c = parseComponents({ components: [
    { name: "ok", low: 1, typical: 2, high: 3, certain: true },
    { name: "nan", low: "x", typical: 2, high: 3 },
    { low: 1, typical: 2, high: 3 },
  ] });
  assertEquals(c.length, 1);
});

Deno.test("canonicalKey is order- and case-insensitive on facts", () => {
  assertEquals(
    canonicalKey({ jobType: "other", job: "Install owned outdoor sauna", facts: ["run_ft 40", "capacity 9kw"] }),
    canonicalKey({ jobType: "other", job: "install  owned outdoor sauna", facts: ["capacity 9KW", "run_ft 40", "run_ft 40"] }),
  );
});

Deno.test("canonicalKey: same job in different words or order shares one key", () => {
  // Reported 2026-10-03: two AI runs, $2k–4.4k vs $2.4k–10k.
  assertEquals(
    canonicalKey({ jobType: "other", job: "install outdoor sauna", facts: ["location outdoor"] }),
    canonicalKey({ jobType: "other", job: "install sauna outdoor", facts: ["location outdoor"] }),
  );
  // A taxonomy job keys on its id, whatever the model wrote as the phrase.
  assertEquals(
    canonicalKey({ jobType: "roofing.repair", job: "patch flat roof", facts: [] }),
    canonicalKey({ jobType: "roofing.repair", job: "repair leaking flat roof section", facts: [] }),
  );
});

Deno.test("factToken buckets numbers so nearby sizes share a price", () => {
  assertEquals(factToken("run_ft 40"), factToken("run_ft 45"));
  assertEquals(factToken("run_ft 40") === factToken("run_ft 150"), false);
  assertEquals(factToken("area_sqft 10"), factToken("area_sqft 20"));
  assertEquals(factToken("location Outdoor"), "location:outdoor");
});

Deno.test("canonicalKey: a taxonomy job ignores descriptive extras and unknowns", () => {
  // "Patch flat roof" vs "Patch my flat roof" ran two AI estimates (2026-10-03).
  assertEquals(
    canonicalKey({ jobType: "roofing.repair", job: "patch flat roof", facts: ["scope patch", "material flat"] }),
    canonicalKey({ jobType: "roofing.repair", job: "patch my flat roof", facts: ["permit unknown"] }),
  );
  // Real price drivers still split it.
  assertEquals(
    canonicalKey({ jobType: "roofing.repair", job: "patch flat roof", facts: ["area_sqft 10"] }) ===
      canonicalKey({ jobType: "roofing.repair", job: "patch flat roof", facts: ["area_sqft 300"] }),
    false,
  );
});
