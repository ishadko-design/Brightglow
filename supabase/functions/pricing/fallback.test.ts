// Category-fallback classification tests.
//
// Why this file exists: real requests arrive under the wrong category — the
// app's category guess or the user's own tap doesn't match the work. The
// categorized keyword path then lands on the category-general entry and the
// request declines, even though the taxonomy holds the exact job. These are
// real classification_cache rows (2026-09) where the LLM returned null and
// the keyword path declined.
//
// classifyWithCategoryFallback retries without the category (then
// stem-ignoring) and only ever returns a specific entry. Every case below
// declined before the fallback; the "stays declined" cases pin the honest
// behavior for requests the taxonomy genuinely doesn't cover.
//
//   deno test --allow-read --allow-env fallback.test.ts

import { assertEquals } from "jsr:@std/assert@1";
import {
  classifyJobType,
  classifyWithCategoryFallback,
} from "./pricingEngine.ts";

interface Case {
  category: string;
  description: string;
  /** Expected job_type after fallback, or null when it must still decline. */
  expect: string | null;
  why: string;
}

const CASES: Case[] = [
  // --- wrong-category requests the taxonomy covers -------------------
  {
    category: "Plumbing",
    description: "repair leaking downspout joint, downspout, 4 inch diameter",
    expect: "roofing.gutter_repair",
    why: "downspout is a gutter part; was plumbing.pipe_repair $150-1041",
  },
  {
    category: "HVAC",
    description:
      "replace the dishwasher, dishwasher, white, built-in under counter, existing fixture already plumbed and wired",
    expect: "appliances.dishwasher_install",
    why: "'already plumbed' stem-hijacked the pool to Plumbing; needs the stem-ignoring stage",
  },
  {
    category: "Tires",
    description:
      "replace bathtub faucet and shower valve trim kit, bathtub with tub/shower trim kit, matte black finish, diver",
    expect: "plumbing.shower_valve",
    why: "user tapped the wrong category; description is unambiguous",
  },
  {
    category: "Electrical",
    description: "brass door hinged interior knob panel replace single solid swings wood",
    expect: "windows_doors.door_repair",
    why: "door repair browsed under Electrical",
  },
  {
    category: "",
    description: "Replace metal trim above sliding door",
    expect: "carpentry.exterior_trim",
    why: "the 'door' stem narrowed the pool to Windows & Doors and hid the priority-1 'metal trim' keyword — a 7-ft trim priced as a $1.4k-$4.3k door replacement (live 2026-09-12)",
  },
  {
    category: "Windows & Doors",
    description: "Replace metal trim above sliding door",
    expect: "carpentry.exterior_trim",
    why: "trim veto on sliding_door declines the miscategorized pool, then the fallback reroutes to the trim entry",
  },
  {
    category: "",
    description: "doorbell not working",
    expect: "electrical.doorbell",
    why: "'door' stem hijacked it to Windows & Doors; needs the stem-ignoring stage",
  },
  // --- requests the taxonomy genuinely doesn't cover: still decline ----
  {
    category: "HVAC",
    description: "replace stairs",
    expect: null,
    why: "no stair-rebuild entry; a decline beats a guessed price",
  },
  {
    category: "Carpentry",
    description:
      "repair the ornate iron gate with rusted top rail, iron gate, black, ornate scrollwork, rust on top rail",
    expect: null,
    why: "no iron-gate entry",
  },
  {
    category: "Tires",
    description:
      "repair worn wooden staircase treads and stringers, wood staircase, carpeted treads, multiple steps visible",
    expect: null,
    why: "staircase rebuild isn't in the taxonomy",
  },
  {
    category: "Appliances",
    description: "replace the under-cabinet range hood",
    expect: null,
    why: "range hood is a different job; the 'hood' veto keeps it declining honestly",
  },
  // --- regressions: good results must not change -----------------------
  {
    category: "Plumbing",
    description: "faucet dripping",
    expect: "plumbing.faucet_repair",
    why: "specific categorized result is never overridden",
  },
  {
    category: "Appliances",
    description: "replace the electric range",
    expect: "appliances.range_install",
    why: "bare-noun keyword; was appliances.general -> declined",
  },
  {
    category: "Appliances",
    description: "oven not heating",
    expect: "appliances.oven_range_repair",
    why: "repair phrasing still wins via priority 1 over the bare-noun install",
  },
  {
    category: "",
    description: "fix my roof",
    expect: null,
    why: "bare vague search still declines — behavior unchanged",
  },
  {
    category: "",
    description: "replace the sliding door",
    expect: "windows_doors.sliding_door",
    why: "a real door replacement still prices as a door — the trim veto only fires on trim work",
  },
  {
    category: "Windows & Doors",
    description: "replace the sliding door",
    expect: "windows_doors.sliding_door",
    why: "categorized door replacement is unaffected by the trim veto",
  },
  {
    category: "",
    description: "my roof is leaking",
    expect: "roofing.repair",
    why: "p1 pre-scan only fires on priority >= 1; 'leak' is p0 so the stem path is untouched",
  },
  {
    category: "Plumbing",
    description: "",
    expect: null,
    why: "category chip alone still declines",
  },
];

Deno.test("category fallback rescues wrong-category requests, declines honest gaps", () => {
  const failures: string[] = [];
  for (const c of CASES) {
    const before = classifyJobType(c.category, c.description, [], null, null);
    const got = classifyWithCategoryFallback(c.category, c.description, [], null);
    // General entries decline downstream exactly like null — the priced-vs-
    // declined line is what matters, not which general entry it was.
    const priced = (e: typeof got) => (e && e.keywords.length > 0 ? e.job_type : null);
    const gotType = priced(got);
    const ok = gotType === c.expect;
    console.log(
      `  ${ok ? "PASS" : "FAIL"}  [${c.category || "(none)"}] "${c.description.slice(0, 50)}"\n` +
        `        before: ${priced(before) ?? "decline"} -> after: ${gotType ?? "decline"} (want ${c.expect ?? "decline"}) — ${c.why}`,
    );
    if (!ok) failures.push(`[${c.category}] "${c.description}": got ${gotType}, want ${c.expect}`);
  }
  assertEquals(failures, [], `fallback misses:\n  ${failures.join("\n  ")}`);
});
