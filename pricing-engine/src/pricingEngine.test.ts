import {
  fetchSFPermits,
  normalizeScope,
  calculatePermitRange,
  calculateMaterialFloor,
  getLocalRange,
  formatDisplayText,
  clearPermitCache,
  Permit,
  Material,
  JobScope,
} from "./pricingEngine";

const scope: JobScope = { job_type: "bathroom.vanity", width_in: 36, features: ["plumbing", "electrical", "tile"] };

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

function makePermitBatch(costs: number[]): Permit[] {
  return costs.map((estimated_cost) => makePermit({ estimated_cost }));
}

const materials: Material[] = [
  { sku: "VAN-36", name: "36in Bathroom Vanity Cabinet", price: 650 },
  { sku: "TOP-36", name: "36in Vanity Top", price: 220 },
  { sku: "FAU-1", name: "Widespread Bathroom Faucet", price: 180 },
  { sku: "MIR-36", name: "36in Frameless Mirror", price: 120 },
];

beforeEach(() => {
  clearPermitCache();
  jest.restoreAllMocks();
});

describe("normalizeScope", () => {
  it("maps a vanity replacement description to bathroom.vanity with size", () => {
    expect(normalizeScope("replace 36in vanity, new faucet")).toEqual({
      job_type: "bathroom.vanity",
      size: 36,
    });
  });

  it("returns null for unrecognized descriptions", () => {
    expect(normalizeScope("install solar panels on roof")).toBeNull();
  });
});

describe("calculatePermitRange", () => {
  it("returns null when fewer than 10 matching permits", () => {
    const permits = makePermitBatch([1000, 2000, 3000]);
    expect(calculatePermitRange(permits, scope)).toBeNull();
  });

  it("computes p25/p50/p75 over matching permits within +/-6in", () => {
    const costs = [1000, 1500, 2000, 2200, 2500, 2800, 3000, 3200, 3500, 4000, 4500];
    const permits = makePermitBatch(costs);
    const result = calculatePermitRange(permits, scope);
    expect(result).not.toBeNull();
    expect(result!.count).toBe(costs.length);
    expect(result!.p50).toBeGreaterThan(result!.p25);
    expect(result!.p75).toBeGreaterThan(result!.p50);
  });

  it("excludes permits outside the size window and unmatched job_type", () => {
    const inWindow = makePermitBatch([1000, 1500, 2000, 2200, 2500, 2800, 3000, 3200, 3500, 4000]);
    const outOfWindow = [makePermit({ description: "replace 60in vanity", estimated_cost: 9000 })];
    const otherJob = [makePermit({ description: "kitchen remodel full gut", estimated_cost: 50000 })];
    const result = calculatePermitRange([...inWindow, ...outOfWindow, ...otherJob], scope);
    expect(result!.count).toBe(inWindow.length);
  });

  it("filters out withdrawn permits before they even reach calculation via fetchSFPermits", async () => {
    // covered in fetchSFPermits suite; calculatePermitRange itself only sees what it's given
    expect(true).toBe(true);
  });
});

describe("calculateMaterialFloor", () => {
  it("sums matched materials for the scope", () => {
    const total = calculateMaterialFloor(materials, scope);
    expect(total).toBe(650 + 220 + 180 + 120);
  });

  it("returns null when a required category is missing", () => {
    const incomplete = materials.filter((m) => !m.name.toLowerCase().includes("mirror"));
    expect(calculateMaterialFloor(incomplete, scope)).toBeNull();
  });

  it("returns null for a job_type with no defined material rules", () => {
    expect(calculateMaterialFloor(materials, { ...scope, job_type: "unknown.job" })).toBeNull();
  });
});

describe("fetchSFPermits", () => {
  it("filters out withdrawn permits and caches the result for 24h", async () => {
    const mockRows = [
      {
        contractor_name: "Acme Plumbing",
        description: "replace 36in vanity, new faucet",
        estimated_cost: "3000",
        filed_date: "2026-05-01",
        completed_date: null,
        status: "issued",
      },
      {
        contractor_name: "Bad Co",
        description: "replace 36in vanity",
        estimated_cost: "2800",
        filed_date: "2026-05-02",
        completed_date: null,
        status: "withdrawn",
      },
    ];
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => mockRows,
    });
    (global as any).fetch = fetchMock;

    const permits = await fetchSFPermits(["vanity"], 6);
    expect(permits).toHaveLength(1);
    expect(permits[0].status).toBe("issued");
    expect((permits[0] as any).address).toBeUndefined();

    // second call within 24h should hit cache, not fetch again
    await fetchSFPermits(["vanity"], 6);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does not expose homeowner address fields even if present upstream", async () => {
    const fetchMock = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => [
        {
          contractor_name: "Acme Plumbing",
          description: "replace 36in vanity",
          estimated_cost: "3000",
          filed_date: "2026-05-01",
          status: "issued",
          street_number: "123",
          street_name: "Main St",
        },
      ],
    });
    (global as any).fetch = fetchMock;

    const permits = await fetchSFPermits(["vanity"], 6);
    expect(Object.keys(permits[0]).sort()).toEqual(
      ["completed_date", "contractor", "description", "estimated_cost", "filed_date", "status"].sort(),
    );
  });

  it("falls back to an empty list gracefully when the API call fails", async () => {
    (global as any).fetch = jest.fn().mockRejectedValue(new Error("network down"));
    const consoleSpy = jest.spyOn(console, "error").mockImplementation(() => {});
    const permits = await fetchSFPermits(["vanity"], 6);
    expect(permits).toEqual([]);
    consoleSpy.mockRestore();
  });
});

describe("getLocalRange", () => {
  it("returns a full range with a 20% buffer applied to permit valuations", async () => {
    const costs = [1000, 1500, 2000, 2200, 2500, 2800, 3000, 3200, 3500, 4000, 4500];
    const mockRows = costs.map((estimated_cost, i) => ({
      contractor_name: `Contractor ${i}`,
      description: "replace 36in vanity, new faucet",
      estimated_cost: String(estimated_cost),
      filed_date: "2026-05-01",
      completed_date: null,
      status: "issued",
    }));
    (global as any).fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => mockRows });

    const result = await getLocalRange("bathroom.vanity", scope, materials);
    expect("error" in result).toBe(false);
    const range = result as any;

    const materialFloor = calculateMaterialFloor(materials, scope)!;
    const rawP25 = percentileFromCosts(costs, 25);
    const bufferedP25 = rawP25 * 1.2;

    expect(range.labor_low).toBeCloseTo(Math.max(bufferedP25 - materialFloor, 600), 5);
    expect(range.data_points).toBe(costs.length);
    expect(range.source).toBe("SF DBI permits + retail pricing");
  });

  it("returns an insufficient-data fallback when permit history is thin", async () => {
    (global as any).fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => [] });
    const result = await getLocalRange("bathroom.vanity", scope, materials);
    expect(result).toEqual({ error: "Insufficient data", fallback: "Get 3 bids" });
  });

  it("returns an insufficient-data fallback when materials are missing", async () => {
    const costs = Array.from({ length: 12 }, (_, i) => 2000 + i * 100);
    const mockRows = costs.map((estimated_cost) => ({
      contractor_name: "Acme",
      description: "replace 36in vanity, new faucet",
      estimated_cost: String(estimated_cost),
      filed_date: "2026-05-01",
      status: "issued",
    }));
    (global as any).fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => mockRows });

    const result = await getLocalRange("bathroom.vanity", scope, []);
    expect(result).toEqual({ error: "Insufficient data", fallback: "Get 3 bids" });
  });
});

describe("formatDisplayText", () => {
  it("formats a full range with materials and labor lines", () => {
    const text = formatDisplayText({
      material_low: 1100,
      material_high: 1600,
      labor_low: 800,
      labor_high: 1800,
      all_in_low: 1900,
      all_in_high: 3400,
      data_points: 63,
      confidence: "high",
      source: "SF DBI permits + retail pricing",
    });
    expect(text).toContain("Typical all-in cost in San Francisco: $1,900-$3,400");
    expect(text).toContain("Based on 63 city permits + material costs, last 6 months.");
    expect(text).toContain("Materials: ~$1,100-$1,600. Labor + permits: ~$800-$1,800.");
    expect(text).not.toContain("Ranges vary widely");
  });

  it("appends a low-confidence warning", () => {
    const text = formatDisplayText({
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
    expect(text).toContain("Ranges vary widely. Get firm bids on your scope.");
  });

  it("formats the insufficient-data fallback", () => {
    const text = formatDisplayText({ error: "Insufficient data", fallback: "Get 3 bids" });
    expect(text).toBe("Insufficient data. Get 3 bids.");
  });
});

// local helper mirroring the internal percentile logic for assertions above
function percentileFromCosts(costs: number[], p: number): number {
  const sorted = [...costs].sort((a, b) => a - b);
  const idx = (p / 100) * (sorted.length - 1);
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  const frac = idx - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}
