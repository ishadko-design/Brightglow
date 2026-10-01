import { assertEquals } from "jsr:@std/assert@1";
import { canonicalKey, parseComponents, sumComponents } from "./itemizedEstimate.ts";

Deno.test("sumComponents: certain parts count fully, uncertain to high + half typical", () => {
  const r = sumComponents([
    { name: "permit", low: 200, typical: 300, high: 500, certain: true },
    { name: "circuit", low: 1000, typical: 1500, high: 2200, certain: true },
    { name: "trench", low: 800, typical: 1200, high: 2000, certain: false },
  ]);
  assertEquals(r, { low: 1200, typical: 2400, high: 4700 });
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
    canonicalKey({ job: "Install owned outdoor sauna", facts: ["run 25-60 ft", "Heater 9 kw"] }),
    canonicalKey({ job: "install  owned outdoor sauna", facts: ["heater 9 kw", "run 25-60 ft", "run 25-60 ft"] }),
  );
});
