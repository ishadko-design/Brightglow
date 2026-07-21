// Accuracy harness — "how wrong are we, against sources we didn't build from?"
//
// This is the counterpart to calibration.test.ts, and the two answer different
// questions. calibration re-checks the catalog against the figures it was BUILT
// from (internal consistency, per-item, at national wages, quantity 1).
// This file runs realistic user queries through the FULL production pipeline
// (estimatePipeline.ts — classification, quantity resolution, add-ons,
// composition, service minimums) and scores the result against HELD-OUT
// published ranges in groundTruth.ts.
//
// It prints a scorecard on every run. The assertions at the bottom are
// RATCHETS: they encode the accuracy we have already achieved, so a change
// that makes the engine worse fails. When accuracy improves, tighten them.
//
//   deno test --allow-read --allow-env accuracy.test.ts
//
// A failure here is not automatically "the price is wrong" — the same number
// moves if the classifier picks a different job or the quantity default is
// off. The per-case output names which, because to a user they're the same bug.

import { assert } from "jsr:@std/assert@1";
import { estimateInHouse } from "./estimatePipeline.ts";
import { GROUND_TRUTH, type GroundTruthCase } from "./groundTruth.ts";

interface Scored {
  c: GroundTruthCase;
  /** Engine output, or null when it declined to price. */
  got: { low: number; typical: number; high: number } | null;
  jobType: string | null;
  classifiedRight: boolean;
  /** Signed error of engine typical vs the midpoint of the published band. */
  error: number | null;
  /** Engine band intersects the published band at all. */
  overlaps: boolean;
  /** Engine typical sits inside the published band. */
  inBand: boolean;
}

function score(c: GroundTruthCase): Scored {
  const r = estimateInHouse({
    category: c.category,
    description: c.query,
    vehicle: c.vehicle ?? null,
  });
  const jobType = r.kind === "insufficient" ? r.entry?.job_type ?? null : r.entry.job_type;
  const classifiedRight = jobType === c.expectJobType;

  if (r.kind !== "range") {
    return { c, got: null, jobType, classifiedRight, error: null, overlaps: false, inBand: false };
  }
  const mid = (c.low + c.high) / 2;
  return {
    c,
    got: { low: r.low, typical: r.typical, high: r.high },
    jobType,
    classifiedRight,
    error: (r.typical - mid) / mid,
    overlaps: r.high >= c.low && r.low <= c.high,
    inBand: r.typical >= c.low && r.typical <= c.high,
  };
}

function median(xs: number[]): number {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

const pct = (n: number) => `${(n * 100).toFixed(0)}%`;
const signed = (n: number) => `${n >= 0 ? "+" : ""}${(n * 100).toFixed(0)}%`;

function report(rows: Scored[], title: string): void {
  const errs = rows.filter((r) => r.error !== null && !r.c.wide).map((r) => Math.abs(r.error!));
  const covered = rows.filter((r) => r.got).length;
  console.log(`\n  ── ${title} ─────────────────────────────────`);
  console.log(`  cases            ${rows.length}`);
  console.log(`  priced           ${covered}/${rows.length} (${pct(covered / rows.length)})`);
  console.log(
    `  classified right ${rows.filter((r) => r.classifiedRight).length}/${rows.length}`,
  );
  console.log(`  typical in band  ${rows.filter((r) => r.inBand).length}/${rows.length}`);
  console.log(`  band overlaps    ${rows.filter((r) => r.overlaps).length}/${rows.length}`);
  console.log(`  median abs error ${pct(median(errs))}`);
  const worst = [...rows]
    .filter((r) => r.error !== null)
    .sort((a, b) => Math.abs(b.error!) - Math.abs(a.error!));
  for (const r of worst) {
    const flag = !r.classifiedRight ? " CLASSIFY" : r.inBand ? "" : " OFF-BAND";
    console.log(
      `    ${signed(r.error!).padStart(6)}  ${r.c.query.padEnd(40)} ` +
        `got ${Math.round(r.got!.typical).toString().padStart(6)} ` +
        `vs ${r.c.low}–${r.c.high}${flag}`,
    );
  }
  for (const r of rows.filter((x) => !x.got)) {
    console.log(`    NO PRICE  ${r.c.query.padEnd(40)} (job_type ${r.jobType ?? "none"})`);
  }
}

const all = GROUND_TRUTH.map(score);
const home = all.filter((r) => r.c.vertical === "home");
const auto = all.filter((r) => r.c.vertical === "auto");

Deno.test("accuracy scorecard vs held-out published prices", () => {
  report(home, "HOME");
  report(auto, "AUTO");
  report(all, "ALL");
});

// --- ratchets ---------------------------------------------------------
// Thresholds encode achieved accuracy. Tighten as the engine improves; never
// loosen one to make a regression pass.

Deno.test("every held-out case produces a price", () => {
  const missing = all.filter((r) => !r.got).map((r) => `${r.c.query} → ${r.jobType ?? "none"}`);
  assert(missing.length === 0, `engine declined to price:\n  ${missing.join("\n  ")}`);
});

Deno.test("every held-out case classifies to the expected job type", () => {
  const wrong = all
    .filter((r) => !r.classifiedRight)
    .map((r) => `${r.c.query} → got ${r.jobType ?? "none"}, want ${r.c.expectJobType}`);
  assert(wrong.length === 0, `misclassified:\n  ${wrong.join("\n  ")}`);
});

Deno.test("engine band overlaps the published band in every case", () => {
  const miss = all
    .filter((r) => r.got && !r.overlaps)
    .map((r) =>
      `${r.c.query}: got ${Math.round(r.got!.low)}–${Math.round(r.got!.high)} vs published ${r.c.low}–${r.c.high}`
    );
  assert(miss.length === 0, `no overlap at all:\n  ${miss.join("\n  ")}`);
});

Deno.test("median absolute error stays within the ratchet", () => {
  const errs = all.filter((r) => r.error !== null && !r.c.wide).map((r) => Math.abs(r.error!));
  const m = median(errs);
  assert(m <= RATCHET_MEDIAN_ERROR, `median abs error ${pct(m)} exceeds ratchet ${pct(RATCHET_MEDIAN_ERROR)}`);
});

Deno.test("no single case is off by more than the outlier ratchet", () => {
  const bad = all
    .filter((r) => r.error !== null && !r.c.wide && Math.abs(r.error!) > RATCHET_WORST_ERROR)
    .map((r) => `${r.c.query}: ${signed(r.error!)} (got ${Math.round(r.got!.typical)}, published ${r.c.low}–${r.c.high})`);
  assert(bad.length === 0, `beyond ${pct(RATCHET_WORST_ERROR)}:\n  ${bad.join("\n  ")}`);
});

// Ratchet history — tighten only, and only with the run that earned it.
//   2026-07-20  baseline           median 16%, worst +68%, 11/14 in band
//   2026-07-20  after 4 fixes      median  4%, worst -24%, 19/19 in band
// The four: the tankless/mini-split/metal-roof classifier priority bug, the
// moto vertical (variants + vehicle plumbing), a corrected roofing ground
// truth, and three genuinely low catalog items (water heater, central AC,
// starter).
/** Median absolute error across held-out cases. */
const RATCHET_MEDIAN_ERROR = 0.08;
/** No single held-out case may miss by more than this. */
const RATCHET_WORST_ERROR = 0.28;

// --- regional behaviour ------------------------------------------------
// Held-out sources publish national figures, so regional accuracy can't be
// scored against them directly. What IS checkable is that the regional
// machinery moves prices in the right direction and by a sane amount.

Deno.test("expensive metros price above national, cheap markets below", () => {
  const q = { category: "Plumbing", description: "replace my water heater" };
  const national = estimateInHouse(q);
  const sf = estimateInHouse({ ...q, zip: "94110" });
  const rural = estimateInHouse({ ...q, zip: "59718" }); // Bozeman MT
  assert(national.kind === "range" && sf.kind === "range" && rural.kind === "range");
  assert(sf.typical > national.typical, `SF ${sf.typical} should exceed national ${national.typical}`);
  assert(
    rural.typical < sf.typical,
    `rural MT ${rural.typical} should sit below SF ${sf.typical}`,
  );
  // Sanity bound: regional spread is real but not unbounded. A >2x swing on
  // the same job means the wage table or the cost factor has gone wrong.
  assert(
    sf.typical / rural.typical < 2,
    `regional spread ${(sf.typical / rural.typical).toFixed(2)}x is implausible`,
  );
});
