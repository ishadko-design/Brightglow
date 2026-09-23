import { assertEquals } from "jsr:@std/assert@1";
import { buildUserMessage, validateEstimate } from "./llmEstimate.ts";

const reply = (o: Record<string, unknown>) => JSON.stringify(o);

Deno.test("validateEstimate accepts a sane range", () => {
  assertEquals(
    validateEstimate(reply({ priceable: true, low: 1000, typical: 1900, high: 4000 })),
    { low: 1000, typical: 1900, high: 4000 },
  );
});

Deno.test("validateEstimate declines anything implausible", () => {
  // Model said it can't price it.
  assertEquals(validateEstimate(reply({ priceable: false, low: 0, typical: 0, high: 0 })), null);
  // Malformed / missing.
  assertEquals(validateEstimate(undefined), null);
  assertEquals(validateEstimate("not json"), null);
  assertEquals(validateEstimate(reply({ priceable: true, low: 100, high: 200 })), null);
  // Out of order.
  assertEquals(validateEstimate(reply({ priceable: true, low: 500, typical: 300, high: 900 })), null);
  // Below a truck roll / above a local quote.
  assertEquals(validateEstimate(reply({ priceable: true, low: 5, typical: 20, high: 50 })), null);
  assertEquals(validateEstimate(reply({ priceable: true, low: 400000, typical: 600000, high: 900000 })), null);
  // A range so wide it says nothing.
  assertEquals(validateEstimate(reply({ priceable: true, low: 100, typical: 800, high: 5000 })), null);
});

Deno.test("buildUserMessage carries location and vehicle", () => {
  const m = buildUserMessage({ description: "fix brakes", category: "Repair", zip: "94015", state: "CA", vehicle: "moto" });
  assertEquals(m.includes("ZIP 94015, CA"), true);
  assertEquals(m.includes("motorcycle"), true);
  assertEquals(buildUserMessage({ description: "install sauna", category: "" }).includes("national averages"), true);
});
