// AI-vs-formula accuracy on the held-out home ground truth (groundTruth.ts).
// COSTS REAL API CALLS (~19 searched estimates, cached after). Run:
//   SUPABASE_ANON_KEY=… APP_TOKEN=… deno run --allow-net --allow-env --allow-read _ai_accuracy.ts [home|auto]
import { estimateInHouse } from "./estimatePipeline.ts";
import { GROUND_TRUTH } from "./groundTruth.ts";

const URL_ = "https://qxoseyrlbvblpwqzwvvk.supabase.co/functions/v1/pricing";
const anon = Deno.env.get("SUPABASE_ANON_KEY")!, tok = Deno.env.get("APP_TOKEN")!;
const VERT = Deno.args[0] ?? "home";
const cases = GROUND_TRUTH.filter((c) => c.vertical === VERT);

async function ai(q: string, category: string, vehicle?: string) {
  const r = await fetch(URL_, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${anon}`, "x-app-token": tok },
    body: JSON.stringify({ category, description: q, force_ai: true, ...(vehicle ? { vehicle } : {}) }),
  });
  const d = (await r.json()).range;
  return { low: d.all_in_low, typical: d.all_in_typical, high: d.all_in_high, searched: !!d.searched, src: r.headers.get("x-cache") };
}

const rows = await Promise.all(cases.map(async (c) => {
  const f = estimateInHouse({ category: c.category, description: c.query, vehicle: c.vehicle ?? null });
  const formula = f.kind === "range" ? { low: f.low, typical: f.typical, high: f.high } : null;
  let a = null;
  try { a = await ai(c.query, c.category, c.vehicle); } catch { /* none */ }
  return { c, formula, a };
}));

const mid = (c: { low: number; high: number }) => (c.low + c.high) / 2;
const err = (t: number | undefined, c: { low: number; high: number }) => t ? Math.abs(t - mid(c)) / mid(c) : NaN;
const inBand = (t: number | undefined, c: { low: number; high: number }) => !!t && t >= c.low && t <= c.high;
const med = (xs: number[]) => { const s = xs.filter(Number.isFinite).sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : NaN; };
const k = (n: number) => n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${Math.round(n)}`;

console.log("job | published | formula typ | AI typ (searched?)");
for (const { c, formula, a } of rows) {
  console.log(`${c.query.slice(0, 38).padEnd(38)} | ${k(c.low)}-${k(c.high)} | ${formula ? k(formula.typical) + (inBand(formula.typical, c) ? " ✓" : " ✗") : "none"} | ${a ? k(a.typical) + (inBand(a.typical, c) ? " ✓" : " ✗") + (a.searched ? " s" : " k") : "none"}`);
}
const fe = rows.map((r) => err(r.formula?.typical, r.c)), ae = rows.map((r) => err(r.a?.typical, r.c));
console.log(`\nFORMULA: in-band ${rows.filter((r) => inBand(r.formula?.typical, r.c)).length}/${rows.length}, median error ${(med(fe) * 100).toFixed(0)}%, no answer ${rows.filter((r) => !r.formula).length}`);
console.log(`AI:      in-band ${rows.filter((r) => inBand(r.a?.typical, r.c)).length}/${rows.length}, median error ${(med(ae) * 100).toFixed(0)}%, no answer ${rows.filter((r) => !r.a).length}, searched ${rows.filter((r) => r.a?.searched).length}`);
