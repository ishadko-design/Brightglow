// Deno test for the Edge Function port. Mirrors the Node/Jest suite in
// /pricing-engine/src/pricingEngine.test.ts — same fixtures, same
// assertions, just exercising the Deno-side pure functions (no HTTP/cache).

import { assertEquals, assertExists } from "jsr:@std/assert@1";
import {
  buildLocalRange,
  buildPermitOnlyRange,
  calculateMaterialFloor,
  calculatePermitRange,
  fetchMaterialFloorRaw,
  formatDisplayText,
  normalizeScope,
  type JobScope,
  type Material,
  type Permit,
} from "./pricingEngine.ts";

const scope: JobScope = { job_type: "bathroom.vanity", width_in: 36, features: ["plumbing"] };

function makePermit(overrides: Partial<Permit> = {}): Permit {
  return {
    contractor: "Acme Plumbing",
    description: "replace 36in vanity, new faucet",
    estimated_cost: 3000,
    filed_date: "2026-05-01",
    completed_date: null,
    status: "issued",
    ...overrides,
  };
}

const materials: Material[] = [
  { sku: "VAN-36", name: "36in Bathroom Vanity Cabinet", price: 650 },
  { sku: "TOP-36", name: "36in Vanity Top", price: 220 },
  { sku: "FAU-1", name: "Widespread Bathroom Faucet", price: 180 },
  { sku: "MIR-36", name: "36in Frameless Mirror", price: 120 },
];

Deno.test("normalizeScope maps a vanity description", () => {
  assertEquals(normalizeScope("replace 36in vanity, new faucet"), { job_type: "bathroom.vanity", size: 36 });
});

Deno.test("normalizeScope returns null for unrecognized text", () => {
  assertEquals(normalizeScope("install solar panels"), null);
});

Deno.test("calculatePermitRange returns null under 10 permits", () => {
  const permits = [1000, 2000, 3000].map((estimated_cost) => makePermit({ estimated_cost }));
  assertEquals(calculatePermitRange(permits, scope), null);
});

Deno.test("calculatePermitRange computes percentiles over matching permits", () => {
  const costs = [1000, 1500, 2000, 2200, 2500, 2800, 3000, 3200, 3500, 4000, 4500];
  const permits = costs.map((estimated_cost) => makePermit({ estimated_cost }));
  const result = calculatePermitRange(permits, scope);
  assertExists(result);
  assertEquals(result!.count, costs.length);
});

Deno.test("calculateMaterialFloor sums matched materials", () => {
  assertEquals(calculateMaterialFloor(materials, scope), 650 + 220 + 180 + 120);
});

Deno.test("calculateMaterialFloor returns null when a category is missing", () => {
  const incomplete = materials.filter((m) => !m.name.toLowerCase().includes("mirror"));
  assertEquals(calculateMaterialFloor(incomplete, scope), null);
});

Deno.test("buildLocalRange applies the 20% permit buffer and $600 labor floor", () => {
  const range = buildLocalRange({ p25: 2000, p50: 2800, p75: 3500, count: 42 }, 1170);
  // p25 buffered = 2400, minus materials 1170 = 1230 (above the 600 floor)
  assertEquals(range.labor_low, 1230);
  assertEquals(range.confidence, "high");
});

Deno.test("formatDisplayText renders the full range and low-confidence warning", () => {
  const text = formatDisplayText({
    materials_included: true,
    material_low: 1100,
    material_high: 1600,
    labor_low: 800,
    labor_high: 1800,
    all_in_low: 1900,
    all_in_high: 3400,
    data_points: 11,
    confidence: "low",
    source: "SF DBI permits + retail pricing",
  });
  assertEquals(text.includes("Typical all-in cost in San Francisco: $1,900-$3,400"), true);
  assertEquals(text.includes("Ranges vary widely. Get firm bids on your scope."), true);
});

Deno.test("formatDisplayText renders the insufficient-data fallback", () => {
  assertEquals(formatDisplayText({ error: "Insufficient data", fallback: "Get 3 bids" }), "Insufficient data. Get 3 bids.");
});

Deno.test("buildPermitOnlyRange derives a range from permits alone, explicitly labeled", () => {
  const range = buildPermitOnlyRange({ p25: 2000, p50: 2800, p75: 3500, count: 42 });
  assertEquals(range.materials_included, false);
  assertEquals(range.all_in_low, 2400); // 2000 * 1.2 buffer
  assertEquals(range.all_in_high, 4200); // 3500 * 1.2 buffer
  assertEquals(range.data_points, 42);
  assertEquals(range.confidence, "high");
  assertEquals(range.source.includes("permit data only"), true);
});

Deno.test("formatDisplayText explicitly calls out permit-only ranges as permit data", () => {
  const range = buildPermitOnlyRange({ p25: 2000, p50: 2800, p75: 3500, count: 11 });
  const text = formatDisplayText(range);
  assertEquals(text.includes("permit data only"), true);
  assertEquals(text.includes("Ranges vary widely"), false); // count 11 -> confidence "med", not "low"
});

Deno.test("formatDisplayText appends the low-confidence warning to a thin permit-only range", () => {
  const range = buildPermitOnlyRange({ p25: 2000, p50: 2800, p75: 3500, count: 10 });
  assertEquals(range.confidence, "low");
  const text = formatDisplayText(range);
  assertEquals(text.includes("Ranges vary widely. Get firm bids on your scope."), true);
});

Deno.test("fetchMaterialFloorRaw sources one priced material per required category", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = ((_input: RequestInfo | URL) =>
    Promise.resolve(
      new Response(
        JSON.stringify({ products: [{ product_id: "abc123", title: "36 in. Bath Vanity Cabinet", price: 650 }] }),
        { status: 200 },
      ),
    )) as typeof fetch;

  try {
    const materials = await fetchMaterialFloorRaw(scope, "test-key");
    assertExists(materials);
    assertEquals(materials!.length, 4); // vanity, top, faucet, mirror
    assertEquals(materials!.every((m) => m.price === 650), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("fetchMaterialFloorRaw returns null without an API key", async () => {
  const materials = await fetchMaterialFloorRaw(scope, "");
  assertEquals(materials, null);
});

Deno.test("fetchMaterialFloorRaw returns null when a category has no priced result", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (() =>
    Promise.resolve(new Response(JSON.stringify({ products: [] }), { status: 200 }))) as typeof fetch;

  try {
    const materials = await fetchMaterialFloorRaw(scope, "test-key");
    assertEquals(materials, null);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("normalizeScope maps flagship jobs for the newly covered categories", () => {
  assertEquals(normalizeScope("water heater replacement"), { job_type: "plumbing.water_heater", size: null });
  assertEquals(normalizeScope("electrical panel upgrade"), { job_type: "electrical.panel", size: null });
  assertEquals(normalizeScope("furnace replacement"), { job_type: "hvac.furnace", size: null });
  assertEquals(normalizeScope("replace window 30in"), { job_type: "windows_doors.window", size: 30 });
  assertEquals(normalizeScope("build a new deck"), { job_type: "carpentry.deck", size: null });
});

Deno.test("fetchMaterialFloorRaw sources a single material for non-dimensional job types", async () => {
  const panelScope: JobScope = { job_type: "electrical.panel", width_in: 36, features: [] };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    const q = new URL(url).searchParams.get("q") ?? "";
    return Promise.resolve(
      new Response(JSON.stringify({ products: [{ product_id: "x", title: q, price: 250 }] }), { status: 200 }),
    );
  }) as typeof fetch;

  try {
    const materials = await fetchMaterialFloorRaw(panelScope, "test-key");
    assertExists(materials);
    assertEquals(materials!.length, 1);
    assertEquals(calculateMaterialFloor(materials!, panelScope), 250);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("fetchMaterialFloorRaw uses width_in for windows_doors.window", async () => {
  const windowScope: JobScope = { job_type: "windows_doors.window", width_in: 30, features: [] };
  const originalFetch = globalThis.fetch;
  let capturedQuery = "";
  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    capturedQuery = new URL(url).searchParams.get("q") ?? "";
    return Promise.resolve(
      new Response(JSON.stringify({ products: [{ product_id: "x", title: capturedQuery, price: 300 }] }), { status: 200 }),
    );
  }) as typeof fetch;

  try {
    await fetchMaterialFloorRaw(windowScope, "test-key");
    assertEquals(capturedQuery.includes("30"), true);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("fetchMaterialFloorRaw sources tub/toilet/vanity/tile for bathroom.full", async () => {
  const fullScope: JobScope = { job_type: "bathroom.full", width_in: 60, features: [] };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    const q = new URL(url).searchParams.get("q") ?? "";
    return Promise.resolve(
      new Response(
        JSON.stringify({ products: [{ product_id: "x", title: q, price: 100 }] }),
        { status: 200 },
      ),
    );
  }) as typeof fetch;

  try {
    const materials = await fetchMaterialFloorRaw(fullScope, "test-key");
    assertExists(materials);
    assertEquals(materials!.length, 4);
    assertEquals(calculateMaterialFloor(materials!, fullScope), 400);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
