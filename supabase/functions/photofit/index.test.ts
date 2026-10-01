import { assertEquals } from "jsr:@std/assert@1";
import { buildPrompt, mapVerdicts, parseBusinesses } from "./index.ts";

const biz = parseBusinesses([
  { id: "a", name: "Aguilar Electric", photos: [{ url: "u1", tags: ["breaker panel", "electrical"] }, { url: "u2", tags: ["sauna", "heater", "wiring"] }], reviews: ["Wired our hot tub"] },
  { id: "b", name: "San Fran Electric", photos: [{ url: "u3", tags: ["meter bank"] }], reviews: [] },
  { id: "", photos: [] }, // dropped: no id
]);

Deno.test("parseBusinesses drops id-less rows and keeps photos", () => {
  assertEquals(biz.map((b) => b.id), ["a", "b"]);
  assertEquals(biz[0].photos.length, 2);
});

Deno.test("buildPrompt numbers businesses and photos and carries the spec", () => {
  const p = buildPrompt({ title: "sauna electrical hookup", spec: { photo_reject: ["breaker panel close-up"] } }, biz);
  assertEquals(p.includes("[0] Aguilar Electric"), true);
  assertEquals(p.includes("photo 1: sauna, heater, wiring"), true);
  assertEquals(p.includes("photo_reject: breaker panel close-up"), true);
});

Deno.test("mapVerdicts maps indices to urls and drops out-of-range", () => {
  const v = mapVerdicts(JSON.stringify({ businesses: [
    { index: 0, relevant_photos: [1, 1, 7], fit: 3, reason: "hot tub wiring in reviews" },
    { index: 1, relevant_photos: [], fit: 1, reason: "should be blanked" },
    { index: 9, relevant_photos: [0], fit: 3, reason: "" },
  ] }), biz);
  assertEquals(v, [
    { id: "a", fit: 3, relevant: ["u2"], reason: "hot tub wiring in reviews" },
    { id: "b", fit: 1, relevant: [], reason: "" },
  ]);
});
