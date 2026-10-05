import { assertEquals } from "jsr:@std/assert@1";
import { minHomeQuestions } from "./priceFloor.ts";

Deno.test("size-driven home trades need two answers before finishing, others one", () => {
  assertEquals(minHomeQuestions("Roofing"), 2);
  assertEquals(minHomeQuestions("Flooring"), 2);
  assertEquals(minHomeQuestions("Electrical"), 1);
  assertEquals(minHomeQuestions(""), 1);
  assertEquals(minHomeQuestions(undefined), 1);
});

import { minQuestions } from "./priceFloor.ts";
Deno.test("auto floor: body & paint needs 2, others 0", () => {
  assertEquals(minQuestions("auto_moto", "Body & Paint"), 2);
  assertEquals(minQuestions("auto_moto", "Repair"), 0);
  assertEquals(minQuestions("home", "Roofing"), 2);
});
