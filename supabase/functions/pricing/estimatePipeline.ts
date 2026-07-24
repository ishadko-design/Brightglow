// The in-house estimate pipeline, extracted from index.ts so that the accuracy
// harness measures the SAME code path production serves.
//
// This was previously inline in the Deno.serve handler, which meant any test
// had to re-implement the sequence (classify → quantity → general-suppression →
// sizing → add-ons → compose → service minimum) and would silently drift from
// what users actually get. A harness that scores a re-implementation measures
// nothing. index.ts now calls this; accuracy.test.ts calls this.
//
// Scope: the in-house path only (EPCI_ENABLED=false, the live configuration).
// index.ts keeps the dormant EPCI branch and owns HTTP, caching, and the LLM
// classifier — the LLM's pick arrives here as `entryOverride`.
//
// "Labor only" survives for Auto & moto ONLY. On a vehicle, a shop bills a
// posted hourly rate against a book time and the parts are a separate line, so
// a labor figure is how the trade actually quotes. Contractor work is sold as
// one all-in number, so a labor figure there is not a partial answer, it's a
// fabricated one: "Install solar panels" showed "~$270 labor only" against a
// real $15–25k (2026-07-20/22). Unmodelled home jobs decline.

import {
  applyServiceMinimum,
  combineSizeScope,
  computeInHouseItems,
  emergencyFactor,
  laborOnlyEstimate,
  qualityTier,
  sizeScale,
  windowScopeScale,
} from "./inHouseEngine.ts";
import {
  applyMotoVariant,
  calculateComposedRange,
  classifyJobType,
  detectScopeAddOns,
  detectVehicle,
  resolveJobComponents,
  resolveQuantity,
  stripVehicleWords,
  type EPCIItem,
  type JobTypeEntry,
  type Vehicle,
  type Vertical,
} from "./pricingEngine.ts";

export interface EstimateInput {
  category: string;
  description: string;
  zip?: string;
  /** Job type chosen by the LLM classifier in index.ts; overrides the keyword
   *  match when present. Absent in the harness, which scores keyword routing. */
  entryOverride?: JobTypeEntry | null;
  /** Which vehicle, for the Auto & moto vertical. The app sends its Moto/Auto
   *  filter; when it doesn't, the description is checked for a moto word. */
  vehicle?: Vehicle | null;
  /** Which taxonomy to search. Set from the model (or the app's own vertical)
   *  so a vehicle request can never fall into a home entry. */
  vertical?: Vertical | null;
}

export type EstimateResult =
  | {
    kind: "range";
    low: number;
    typical: number;
    high: number;
    confidence: "high" | "med" | "low";
    label: string;
    entry: JobTypeEntry;
    quantity: number;
    isDefaulted: boolean;
  }
  | {
    /** Auto & moto only — hours x local billed rate, parts excluded. */
    kind: "labor";
    low: number;
    typical: number;
    high: number;
    label: string;
    entry: JobTypeEntry;
  }
  | {
    kind: "insufficient";
    /** Why we declined, for the harness's coverage breakdown and the logs. */
    reason: "unclassified" | "general_suppressed" | "no_items";
    entry: JobTypeEntry | null;
  };

export function estimateInHouse(input: EstimateInput): EstimateResult {
  const { category, description, zip } = input;

  // Vehicle first: an explicit filter from the app wins, otherwise read it off
  // the words. Classification then runs against the description with the
  // vehicle noun removed, so "replace motorcycle tires" matches the same
  // "replace tires" keyword a car request would.
  const vehicle = input.vehicle ?? detectVehicle(description);
  const classifyText = vehicle === "moto" ? stripVehicleWords(description) : description;

  let entry = input.entryOverride ??
    classifyJobType(category, classifyText, [], input.vertical ?? null);
  if (!entry) return { kind: "insufficient", reason: "unclassified", entry: null };
  if (vehicle === "moto") entry = applyMotoVariant(entry);

  const trimmedDesc = description.trim();
  const { quantity, isDefaulted } = resolveQuantity(entry, description);
  const isGeneral = entry.keywords.length === 0;

  // The user described a specific job and the best we could do was a
  // category-general bucket — meaning we do NOT model this job. Decline.
  //
  // On a vehicle, a labor figure is a real half of the quote — shops bill a
  // posted rate against book time and itemise parts separately — so Auto & moto
  // still gets one, labelled.
  //
  // For home trades this emitted a figure from a fixed 2.5-hour visit
  // assumption, which is only sane for service-call work. Reported live
  // 2026-07-20 and again 2026-07-22: "Install solar panels" landed on
  // electrical.general and showed "~$270 labor only" against a real 10+ panel
  // install of $15–25k — off by ~100x, and a number a user reasonably reads as
  // the price. The visit-length guess carries no information about a job we by
  // definition didn't model, so it cannot be right except by luck. Contractor
  // work is quoted all-in or not at all.
  //
  // A bare category browse (no description) still gets its general figure
  // below — that IS a fair "typical job for this trade".
  if (isGeneral && trimmedDesc.length >= 3) {
    const isAuto = (input.vertical ?? (vehicle ? "auto" : null)) === "auto";
    const labor = isAuto ? laborOnlyEstimate(entry.trade, zip) : null;
    if (labor) {
      return {
        kind: "labor",
        low: labor.low,
        typical: labor.typical,
        high: labor.high,
        label:
          `Typical labor only — ~${labor.hoursLow}–${labor.hoursHigh} hrs at ~$${
            Math.round(labor.hourlyTypical)
          }/hr locally. Parts extra.`,
        entry,
      };
    }
    return { kind: "insufficient", reason: "general_suppressed", entry };
  }

  const tier = qualityTier(description);
  const size = sizeScale(entry.itemId, description);
  const scope = windowScopeScale(entry.itemId, description);
  const sizing = combineSizeScope(entry.itemId, size, scope);

  const componentTrades = [
    ...new Set(resolveJobComponents(entry.job_type, description).map((c) => c.trade)),
  ];
  const itemsByTrade: Record<string, EPCIItem[]> = {};
  for (const trade of [entry.trade, ...componentTrades]) {
    itemsByTrade[trade] = computeInHouseItems(trade, zip, tier.factor, sizing);
  }

  const addOns = detectScopeAddOns(entry, description);
  const composed = itemsByTrade[entry.trade]
    ? calculateComposedRange(
      itemsByTrade,
      entry,
      quantity,
      description,
      addOns.filter((a) => !a.flat).map((a) => a.itemId),
      addOns.filter((a) => a.flat).map((a) => a.itemId),
    )
    : null;
  if (!composed) return { kind: "insufficient", reason: "no_items", entry };

  const floored = applyServiceMinimum(composed, entry.trade, entry.itemId);

  // Emergency premium applies AFTER the service minimum, so an after-hours call
  // is a multiple of a real floored price, never floored back down.
  const emergency = emergencyFactor(description);
  const range = emergency.emergency
    ? {
      ...floored,
      all_in_low: floored.all_in_low * emergency.factor,
      all_in_typical: floored.all_in_typical * emergency.factor,
      all_in_high: floored.all_in_high * emergency.factor,
    }
    : floored;

  let label = isGeneral ? `Regional avg for ${entry.category}` : "Regional avg";
  const includedLabels = [...addOns.map((a) => a.label), ...range.includedLabels];
  if (includedLabels.length > 0) label += ` — incl. ${includedLabels.join(", ")}`;
  if (scope) label += `${includedLabels.length > 0 ? "," : " —"} ${scope.scope}`;
  if (tier.tier) {
    label += `${includedLabels.length > 0 || scope ? "," : " —"} ${tier.tier} materials`;
  }
  if (emergency.emergency) label += `${includedLabels.length > 0 || scope || tier.tier ? "," : " —"} after-hours rate`;

  return {
    kind: "range",
    low: range.all_in_low,
    typical: range.all_in_typical,
    high: range.all_in_high,
    confidence: isGeneral || isDefaulted ? "low" : "med",
    label,
    entry,
    quantity,
    isDefaulted,
  };
}
