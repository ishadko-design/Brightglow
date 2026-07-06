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
  parseJobType,
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

Deno.test("parseJobType accepts pool ids and rejects everything else", () => {
  const pool = buildClassifierPool(JOB_TYPE_TAXONOMY, CATEGORY_GENERAL, "");
  assertEquals(parseJobType('{"job_type": "windows_doors.sliding_door"}', pool), "windows_doors.sliding_door");
  assertEquals(parseJobType('{"job_type": "none"}', pool), null);
  assertEquals(parseJobType('{"job_type": "made.up"}', pool), null);
  assertEquals(parseJobType("not json", pool), null);
  assertEquals(parseJobType(undefined, pool), null);
});
