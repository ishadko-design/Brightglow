// A/B classifier comparison — Opus 4.8 vs Sonnet 5 (vs Haiku 4.5).
//
// Runs the same set of real requests through each model and reports per-model
// accuracy + wall-clock latency, so a model swap is a measured decision, not a
// guess. COSTS REAL API CALLS (a few dozen). Run:
//
//   ANTHROPIC_API_KEY=<key> deno run --allow-net --allow-env \
//     supabase/functions/pricing/_compare_models.ts
//
// Optional: ANTHROPIC_WORKSPACE_ID=<id> if the key is not workspace-scoped.
// This is a scratch harness, safe to delete after; it is not wired into CI.

import { CATEGORY_GENERAL, JOB_TYPE_TAXONOMY } from "./pricingEngine.ts";
import { buildClassifierPool, classifyWithLLM } from "./llmClassifier.ts";

const KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
if (!KEY) {
  console.error("Set ANTHROPIC_API_KEY to run the comparison.");
  Deno.exit(1);
}

const MODELS = ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001"];

interface Case {
  query: string;
  category: string;
  expectJobType: string; // "" = expect no job (a whole-project decline → grounded)
  expectVehicle: "auto" | "moto" | null;
  why: string;
}

const CASES: Case[] = [
  // --- the two bugs fixed 2026-09-20: the reason we're comparing at all -----
  { query: "Replace the Owen with electric stove", category: "", expectJobType: "appliances.range_install", expectVehicle: null, why: "'electric' is a fuel type, not electrical work — appliance swap" },
  { query: "install a new electric range", category: "Appliances", expectJobType: "appliances.range_install", expectVehicle: null, why: "electric range is an appliance install" },
  { query: "Full structural renovation house 1200 sqft", category: "", expectJobType: "", expectVehicle: null, why: "whole-property project → no single trade; should decline to grounding" },
  // --- vehicle inferred from a marque or colloquialism ----------------------
  { query: "my Ducati needs new rubber", category: "Tires", expectJobType: "auto.tire_replacement", expectVehicle: "moto", why: "marque + 'rubber' slang for tires" },
  { query: "tires for my bike", category: "Tires", expectJobType: "auto.tire_replacement", expectVehicle: "moto", why: "colloquialism, no marque" },
  { query: "new tires for my Yamaha R6", category: "Tires", expectJobType: "auto.tire_replacement", expectVehicle: "moto", why: "model designation only" },
  { query: "the AC in my truck blows warm", category: "Repair", expectJobType: "auto.ac", expectVehicle: "auto", why: "symptom; must not read as home HVAC" },
  // --- job inferred from a symptom rather than a part name ------------------
  { query: "the thing that charges the battery while driving died", category: "Repair", expectJobType: "auto.alternator", expectVehicle: "auto", why: "describes the alternator without naming it" },
  { query: "my car drifts to the right when I let go of the wheel", category: "Tires", expectJobType: "auto.alignment", expectVehicle: "auto", why: "symptom of misalignment" },
  { query: "a rock left a little star in the glass in front of me", category: "Glass", expectJobType: "auto.chip_repair", expectVehicle: "auto", why: "windscreen chip, no 'windshield'" },
  // --- home, to prove the vertical boundary holds --------------------------
  { query: "water keeps pooling under the kitchen sink", category: "Plumbing", expectJobType: "plumbing.pipe_repair", expectVehicle: null, why: "home request must report no vehicle" },
];

interface Score { pass: number; total: number; ms: number }

async function run(model: string): Promise<Score> {
  let pass = 0;
  const t0 = performance.now();
  for (const c of CASES) {
    const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, c.category);
    const got = await classifyWithLLM(pool, c.query, KEY, c.category || undefined, model);
    const job = got.jobs[0]?.jobType ?? null;
    const jobOk = c.expectJobType === "" ? got.jobs.length === 0 : job === c.expectJobType;
    const vehOk = got.vehicle === c.expectVehicle;
    const ok = jobOk && vehOk;
    if (ok) pass++;
    console.log(
      `  ${ok ? "PASS" : "FAIL"}  "${c.query}"\n` +
        `        job ${job ?? "none"} (want ${c.expectJobType || "none"}), ` +
        `vehicle ${got.vehicle ?? "none"} (want ${c.expectVehicle ?? "none"})`,
    );
  }
  return { pass, total: CASES.length, ms: performance.now() - t0 };
}

const results: Record<string, Score> = {};
for (const model of MODELS) {
  console.log(`\n===== ${model} =====`);
  try {
    results[model] = await run(model);
  } catch (err) {
    console.error(`  ${model} errored:`, err instanceof Error ? err.message : err);
  }
}

console.log("\n===== SUMMARY =====");
for (const model of MODELS) {
  const s = results[model];
  if (!s) { console.log(`  ${model.padEnd(28)} — errored`); continue; }
  console.log(
    `  ${model.padEnd(28)} ${s.pass}/${s.total} correct   ` +
      `${(s.ms / CASES.length).toFixed(0)} ms/req avg`,
  );
}
console.log("\nNote: relative $ — Opus 4.8 ≈ 5x Sonnet input / 8x output; Haiku ≈ cheapest.");
