// The clarifying chat must not ask the same question twice.
//
// Reported live 2026-07-23: "About how big is the garage floor?" asked twice
// after the user answered "200-300 sq ft". The model does this inconsistently —
// a range answer seems to trip it — so the prompt alone can't be trusted and a
// deterministic server backstop suppresses the repeat. This covers that
// backstop; importing index.ts would start Deno.serve, so the function is
// exported and tested directly.

import { assert } from "jsr:@std/assert@1";
import { repeatsPriorQuestion } from "./repeatsPriorQuestion.ts";

const asked = (q: string) => [{ role: "assistant", content: q }];

Deno.test("the reported repeat is caught", () => {
  assert(
    repeatsPriorQuestion(
      "About how big is the garage floor?",
      [
        { role: "user", content: "epoxy garage floor" },
        { role: "assistant", content: "About how big is the garage floor?" },
        { role: "user", content: "200-300 sq ft" },
      ],
    ),
  );
});

Deno.test("a lightly reworded repeat is still caught", () => {
  assert(repeatsPriorQuestion("How big is the garage floor, roughly?", asked("About how big is the garage floor?")));
});

Deno.test("a genuinely different question about the same thing is NOT caught", () => {
  // Same noun, different fact — must be allowed through.
  assert(!repeatsPriorQuestion("What material is the garage floor?", asked("How big is the garage floor?")));
});

Deno.test("an unrelated next question is not caught", () => {
  assert(!repeatsPriorQuestion("Is it a car or a motorcycle?", asked("How big is the garage floor?")));
});

Deno.test("the first question is never a repeat", () => {
  assert(!repeatsPriorQuestion("How big is the garage floor?", [{ role: "user", content: "epoxy floor" }]));
});
