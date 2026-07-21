// Tests the pure parts of the LLM fallback classifier — pool building,
// prompt/schema construction, and reply parsing. The Anthropic call itself is
// a thin wrapper around these and is exercised live (its failure mode in
// index.ts is "keyword result stands", never an error to the client).

import { assert, assertEquals } from "jsr:@std/assert@1";
import { CATEGORY_GENERAL, JOB_TYPE_TAXONOMY } from "./pricingEngine.ts";
import {
  buildClassifierPool,
  buildSchema,
  buildSystemPrompt,
  parseClassification,
} from "./llmClassifier.ts";

Deno.test("buildClassifierPool scopes to the category and includes its general entry", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "Plumbing");
  assert(pool.every((e) => e.category === "Plumbing"));
  assert(pool.some((e) => e.job_type === "plumbing.water_heater"));
  assert(pool.some((e) => e.job_type === "plumbing.general"));
});

Deno.test("buildClassifierPool with no category spans the whole taxonomy", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "");
  assert(pool.some((e) => e.job_type === "flooring.hardwood"));
  assert(pool.some((e) => e.job_type === "roofing.general"));
});

Deno.test("buildClassifierPool is empty for uncovered categories", () => {
  // Mold & Pest Control has no taxonomy entries and a null general —
  // classifyWithLLM skips the call entirely on an empty pool.
  assertEquals(buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "Mold & Pest Control"), []);
});

Deno.test("buildSystemPrompt lists every pool id", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "Flooring");
  const prompt = buildSystemPrompt(pool);
  for (const e of pool) assert(prompt.includes(e.job_type));
});

Deno.test("buildSchema enum is the pool plus none", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "HVAC");
  const schema = buildSchema(pool) as {
    properties: { job_type: { enum: string[] } };
  };
  assertEquals(schema.properties.job_type.enum.length, pool.length + 1);
  assert(schema.properties.job_type.enum.includes("none"));
});

Deno.test("parseClassification accepts pool ids and rejects everything else", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "");
  const jt = (t: string | undefined) => parseClassification(t, pool).jobType;
  assertEquals(jt('{"job_type": "windows_doors.sliding_door", "vehicle": "none"}'), "windows_doors.sliding_door");
  assertEquals(jt('{"job_type": "none", "vehicle": "none"}'), null);
  assertEquals(jt('{"job_type": "made.up", "vehicle": "none"}'), null);
  assertEquals(jt("not json"), null);
  assertEquals(jt(undefined), null);
});

Deno.test("parseClassification reads the vehicle, defaulting to null", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "");
  const v = (t: string) => parseClassification(t, pool).vehicle;
  assertEquals(v('{"job_type": "auto.tire_replacement", "vehicle": "moto"}'), "moto");
  assertEquals(v('{"job_type": "auto.tire_replacement", "vehicle": "auto"}'), "auto");
  // "none" and anything unexpected both mean "the text said nothing".
  assertEquals(v('{"job_type": "auto.tire_replacement", "vehicle": "none"}'), null);
  assertEquals(v('{"job_type": "auto.tire_replacement", "vehicle": "truck"}'), null);
  assertEquals(v('{"job_type": "auto.tire_replacement"}'), null);
});

Deno.test("buildSchema constrains vehicle to auto/moto/none", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "Tires");
  const schema = buildSchema(pool) as { properties: { vehicle: { enum: string[] } } };
  assertEquals(schema.properties.vehicle.enum, ["auto", "moto", "none"]);
});

Deno.test("buildSystemPrompt tells the model to infer the vehicle from any signal", () => {
  const prompt = buildSystemPrompt(buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "Tires"));
  // The whole point of moving this off a word list: marques and colloquialisms.
  assert(prompt.includes("Ducati"));
  assert(prompt.includes("two-wheeler"));
  assert(prompt.includes("moto"));
});
