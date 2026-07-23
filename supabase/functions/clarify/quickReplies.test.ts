// The clarifying chat must never ask a question with nothing to tap.
//
// Reported live 2026-07-22: "Is this pipe inside the house, or the main line to
// the street/septic?" rendered with no chips. The client was fine and the server
// usually returns options — the model just decided this particular either/or had
// no "natural options", which the prompt at the time explicitly permitted.
//
// Three defences now: the prompt demands options, the schema sets minItems, and
// index.ts retries with a narrow follow-up call when neither held. This file
// covers the normalization those all funnel through — the part that decides
// whether a retry is even needed.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { GENERIC_REPLIES, normalizeQuickReplies } from "./quickReplies.ts";

Deno.test("a good list passes through untouched", () => {
  const { replies, usable } = normalizeQuickReplies(["Yard", "Under slab", "Not sure"]);
  assertEquals(replies, ["Yard", "Under slab", "Not sure"]);
  assert(usable);
});

Deno.test("empty or absent means retry", () => {
  for (const raw of [[], null, undefined, "nope", 42, {}]) {
    const { usable } = normalizeQuickReplies(raw);
    assert(!usable, `${JSON.stringify(raw)} should not be usable`);
  }
});

Deno.test("a single option is a dead end, same as none", () => {
  // Nothing to choose between — the user is back at the keyboard either way.
  const { usable } = normalizeQuickReplies(["Yes"]);
  assert(!usable);
});

Deno.test("blank and over-long labels are dropped", () => {
  const { replies } = normalizeQuickReplies([
    "  Yard  ",
    "",
    "   ",
    "An option so long it would overflow the chip and wrap the row",
    "Under slab",
  ]);
  assertEquals(replies, ["Yard", "Under slab"]);
});

Deno.test("duplicates collapse and the list caps at four", () => {
  const { replies } = normalizeQuickReplies(["A", "A", "B", "C", "D", "E"]);
  assertEquals(replies, ["A", "B", "C", "D"]);
});

Deno.test("non-string entries are discarded, not stringified", () => {
  // A null must not become the literal chip "null".
  const { replies } = normalizeQuickReplies(["Yard", null, 7, "Under slab"]);
  assertEquals(replies, ["Yard", "Under slab"]);
});

Deno.test("the generic floor is itself a valid set", () => {
  const { replies, usable } = normalizeQuickReplies(GENERIC_REPLIES);
  assert(usable, "the last-resort options must survive their own normalizer");
  assertEquals(replies, GENERIC_REPLIES);
});
