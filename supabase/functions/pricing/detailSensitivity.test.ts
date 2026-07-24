// Does the clarifying chat's work actually reach the price?
//
// The chat asks good questions, the client merges the answers into the
// description, and the engine re-prices — but only if the engine has a lever
// the answer can land on. When it doesn't, every step still "succeeds" and the
// number is identical, which is invisible from either side alone.
//
// Reported live 2026-07-22: "Fix deck, replace shone decks and baby proof"
// priced $14,421, and adding the user's own answers ("100-300 sq ft", "replace
// 20 deck boards") produced $14,421 — to the cent. The only deck item was
// BUILD-A-DECK, per sq ft, defaulting to 300; "20 boards" matched nothing and
// "100-300 sq ft" parsed to the default. Two bugs hiding each other.
//
// So: every detail the chat is told to collect must be a detail the engine
// consumes. Each case below states a request and a more specific version of
// the SAME request. If the price doesn't move, the extra information was
// silently dropped.

import { assert } from "jsr:@std/assert@1";
import { estimateInHouse } from "./estimatePipeline.ts";

function typical(description: string): number | null {
  const r = estimateInHouse({ category: "", description, zip: "94014" });
  return r.kind === "range" ? r.typical : null;
}

interface Case {
  base: string;
  detailed: string;
  /** What the added words are supposed to tell the engine. */
  lever: string;
}

const CASES: Case[] = [
  // The reported case, both halves of it.
  { base: "fix deck", detailed: "fix deck, replace 20 deck boards", lever: "board count" },
  { base: "refinish my deck", detailed: "refinish my deck, 600 sq ft", lever: "deck area" },
  { base: "baby proof deck", detailed: "baby proof deck, 48 linear ft of railing", lever: "railing length" },
  // Area-priced work.
  { base: "replace tiles bathroom", detailed: "replace tiles bathroom, 40 sq ft", lever: "tiled area" },
  { base: "paint interior", detailed: "paint interior, 900 sq ft", lever: "floor area" },
  { base: "install hardwood floors", detailed: "install hardwood floors, 800 sq ft", lever: "floor area" },
  { base: "replace roof", detailed: "replace roof, 2600 sq ft, asphalt shingle roof", lever: "roof area + material" },
  // Count-priced work.
  { base: "replace windows", detailed: "replace 6 windows", lever: "window count" },
  { base: "install solar panels", detailed: "install 32 solar panels", lever: "panel count" },
  { base: "install outlets", detailed: "install 5 outlets", lever: "outlet count" },
  // Painting prep is area-priced: a stated area must move it.
  { base: "remove popcorn ceiling", detailed: "remove popcorn ceiling, 900 sq ft", lever: "ceiling area" },
  { base: "pressure wash my house", detailed: "pressure wash my house, 2200 sq ft", lever: "washed area" },
  // Count-priced electrical: a stated number of lights must move the price.
  { base: "install recessed lighting", detailed: "install 9 recessed lights", lever: "can light count" },
  // Auto: the chat asks full / partial / removal, so that answer must land.
  { base: "wrap car", detailed: "wrap car, partial wrap", lever: "wrap coverage" },
  { base: "wrap car", detailed: "wrap car, removing an old wrap", lever: "wrap vs removal" },
  // Scope words, not sizes.
  { base: "replace windows", detailed: "replace windows, glass only", lever: "replacement scope" },
];

Deno.test("a detail the clarifying chat collects moves the price", () => {
  const inert: string[] = [];
  for (const c of CASES) {
    const base = typical(c.base);
    const detailed = typical(c.detailed);
    if (base === null || detailed === null) {
      inert.push(`${c.lever}: "${c.base}" or "${c.detailed}" produced no price at all`);
      continue;
    }
    // 2% guards against a lever that technically fires but is a rounding
    // artifact. A real answer should move a real amount.
    const moved = Math.abs(detailed - base) / base;
    if (moved < 0.02) {
      inert.push(
        `${c.lever}: "${c.detailed}" = $${detailed.toFixed(0)}, same as "${c.base}" ` +
          `($${base.toFixed(0)}) — the engine has no lever for it`,
      );
    }
  }
  assert(inert.length === 0, `\n  ${inert.join("\n  ")}`);
});

// The other half of the deck bug: a repair priced as new construction. These
// pairs are the same system, one fixed and one replaced wholesale. A repair
// that costs more than the replacement is always wrong, and it is the failure
// users notice first ("deck repair came more expensive than an entire roof").
const REPAIR_VS_REPLACE: Array<{ repair: string; replace: string }> = [
  { repair: "fix deck, replace 20 deck boards", replace: "build a new deck, 300 sq ft" },
  { repair: "refinish my deck, 300 sq ft", replace: "build a new deck, 300 sq ft" },
  { repair: "roof repair, patch a leak", replace: "replace roof, 2000 sq ft" },
  { repair: "solar panel repair", replace: "install solar panels" },
  // HVAC: a service call must never cost more than the whole machine.
  { repair: "AC not cooling", replace: "install central air conditioning" },
  { repair: "furnace wont ignite", replace: "replace gas furnace" },
  { repair: "thermostat not working", replace: "install smart thermostat" },
  // Painting: a patch is not a repaint.
  { repair: "hole in the wall", replace: "paint a 250 sq ft room" },
  { repair: "water stain on ceiling", replace: "paint a 250 sq ft room" },
];

Deno.test("repairing a thing costs less than replacing it outright", () => {
  const inverted: string[] = [];
  for (const { repair, replace } of REPAIR_VS_REPLACE) {
    const r = typical(repair);
    const w = typical(replace);
    // A repair we decline to price is fine — silence isn't a wrong number.
    if (r === null || w === null) continue;
    if (r >= w) {
      inverted.push(
        `"${repair}" ($${r.toFixed(0)}) >= "${replace}" ($${w.toFixed(0)})`,
      );
    }
  }
  assert(inverted.length === 0, `\n  ${inverted.join("\n  ")}`);
});
