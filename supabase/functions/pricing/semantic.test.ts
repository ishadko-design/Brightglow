// Semantic classification tests — the layer that makes arbitrary phrasing work.
//
// Why this file exists: accuracy.test.ts scores the KEYWORD path (it calls the
// pipeline with no classifier), so its numbers describe the fallback, not what
// production runs. Production classifies with the model first. Nothing was
// testing that, which is how the engine shipped able to price "replace tires"
// but not "place tires on motorcycle".
//
// Every case below is phrased so that NO keyword in the taxonomy matches. If
// one starts passing on keywords alone, that's fine — but these must pass
// without them. That's the point: coverage should come from understanding, not
// from someone having thought of the word.
//
// COSTS REAL API CALLS, so it's opt-in and skipped by default:
//   ANTHROPIC_API_KEY=<key> PRICING_SEMANTIC_TEST=1 \
//     deno test --allow-net --allow-env semantic.test.ts

import { assertEquals } from "jsr:@std/assert@1";
import { CATEGORY_GENERAL, JOB_TYPE_TAXONOMY } from "./pricingEngine.ts";
import { buildClassifierPool, classifyWithLLM } from "./llmClassifier.ts";

const KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const ENABLED = Deno.env.get("PRICING_SEMANTIC_TEST") === "1" && KEY !== "";

interface Case {
  query: string;
  category: string;
  expectJobType: string;
  expectVehicle: "auto" | "moto" | null;
  /** Why a keyword matcher cannot get this right. */
  why: string;
}

const CASES: Case[] = [
  // --- vehicle inferred from a marque or colloquialism ------------------
  // These are the reported failure class: the word list knew "harley" and
  // "motorcycle" and nothing else, so these all priced as 4 car tires.
  {
    query: "my Ducati needs new rubber",
    category: "Tires",
    expectJobType: "auto.tire_replacement",
    expectVehicle: "moto",
    why: "marque, plus 'rubber' as slang for tires",
  },
  {
    query: "tires for my bike",
    category: "Tires",
    expectJobType: "auto.tire_replacement",
    expectVehicle: "moto",
    why: "colloquialism, no marque and no 'motorcycle'",
  },
  {
    query: "new tires for my Yamaha R6",
    category: "Tires",
    expectJobType: "auto.tire_replacement",
    expectVehicle: "moto",
    why: "model designation only",
  },
  {
    query: "the AC in my truck blows warm",
    category: "Repair",
    expectJobType: "auto.ac",
    expectVehicle: "auto",
    why: "symptom, not a service name; must not read as home HVAC",
  },

  // --- job inferred from a symptom rather than a part name --------------
  {
    query: "the thing that charges the battery while driving died",
    category: "Repair",
    expectJobType: "auto.alternator",
    expectVehicle: "auto",
    why: "describes the alternator without naming it",
  },
  {
    query: "my car drifts to the right when I let go of the wheel",
    category: "Tires",
    expectJobType: "auto.alignment",
    expectVehicle: "auto",
    why: "symptom of misalignment, no service word",
  },
  {
    query: "a rock left a little star in the glass in front of me",
    category: "Glass",
    expectJobType: "auto.chip_repair",
    expectVehicle: "auto",
    why: "describes a windscreen chip without 'windshield' or 'chip repair'",
  },

  // --- home, to prove the vertical boundary holds -----------------------
  {
    query: "water keeps pooling under the kitchen sink",
    category: "Plumbing",
    expectJobType: "plumbing.pipe_repair",
    expectVehicle: null,
    why: "home request must report no vehicle",
  },
];

Deno.test({
  name: "semantic classification handles phrasings no keyword covers",
  ignore: !ENABLED,
  fn: async () => {
    const failures: string[] = [];
    for (const c of CASES) {
      const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, c.category);
      const got = await classifyWithLLM(pool, c.query, KEY);
      const jobOk = got.jobType === c.expectJobType;
      const vehOk = got.vehicle === c.expectVehicle;
      console.log(
        `  ${jobOk && vehOk ? "PASS" : "FAIL"}  "${c.query}"\n` +
          `        job ${got.jobType ?? "none"} (want ${c.expectJobType}), ` +
          `vehicle ${got.vehicle ?? "none"} (want ${c.expectVehicle ?? "none"}) — ${c.why}`,
      );
      if (!jobOk) failures.push(`${c.query}: job ${got.jobType ?? "none"} != ${c.expectJobType}`);
      if (!vehOk) {
        failures.push(`${c.query}: vehicle ${got.vehicle ?? "none"} != ${c.expectVehicle ?? "none"}`);
      }
    }
    assertEquals(failures, [], `semantic misses:\n  ${failures.join("\n  ")}`);
  },
});
