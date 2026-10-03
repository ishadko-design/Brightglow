// AI-first, itemized, web-grounded home estimate (2026-09-30).
//
// Why: the catalog formula only knows ~300 discrete jobs and breaks on anything
// else; the knowledge-only AI band was sensible but drifted run to run (the
// sauna install priced $1.2k-3.2k, $1.8k-5.5k, $8k-20k on different paths).
// The product decision: rely on the AI, but make it CONSISTENT and GROUNDED:
//
//   1. canonicalize — the request becomes a stable job + sorted price facts
//      ("install owned outdoor sauna" + ["heater 9 kw", "run 25-60 ft", ...]),
//      so the same job maps to the same cache key however it was phrased.
//   2. itemize — the model lists every component of the work with its own
//      low/typical/high; the TOTAL is summed here in code, so the number always
//      equals its parts (uncertain parts count toward high, half toward typical).
//   3. ground — the full request runs the itemization WITH web search for
//      current local prices and caches it per (area, job key); the fast request
//      serves that cache, or a knowledge itemization while the searched one
//      fills in the background.
//
// The catalog formula is kept as a fallback (AI unavailable) and as a
// guardrail signal (logged divergence), never as the shown number.

import Anthropic from "npm:@anthropic-ai/sdk";
import { JOB_TYPE_TAXONOMY } from "./pricingEngine.ts";

/** Last failure reason, for the debug probe in index.ts. */
export let lastItemizeError = "";

export interface Component {
  name: string;
  low: number;
  typical: number;
  high: number;
  /** false = may or may not be needed (an unknown in the scope). */
  certain: boolean;
}

export interface ItemizedEstimate {
  low: number;
  typical: number;
  high: number;
  basis: string;
  components: Component[];
  /** true when produced with live web search. */
  searched: boolean;
}

export interface CanonicalJob {
  /** Taxonomy job_type (e.g. "roofing.repair"), or "other" when none fits. */
  jobType?: string;
  job: string;
  /** "<name> <value>", name from FACT_NAMES. */
  facts: string[];
}

const MODEL = "claude-sonnet-5";
/** Basic web search: the 20260209 dynamic-filtering variant ran 30-90s+ and
 *  timed out in the background (2026-09-30). */
export const SEARCH_TOOL = "web_search_20250305";

function client(apiKey: string, timeout: number): Anthropic {
  const workspaceId = Deno.env.get("ANTHROPIC_WORKSPACE_ID") ?? "";
  return new Anthropic({
    apiKey,
    timeout,
    maxRetries: 0,
    ...(workspaceId ? { defaultHeaders: { "anthropic-workspace-id": workspaceId } } : {}),
  });
}

const textOf = (r: Anthropic.Message) =>
  r.content.filter((b): b is Anthropic.TextBlock => b.type === "text").map((b) => b.text).join("\n");

// ── 1. canonicalize ─────────────────────────────────────────────────────────

// The cache key is the JOB, not the wording (2026-10-03: "install outdoor
// sauna" and "install sauna outdoor" were priced as two separate AI runs, at
// $2k–4.4k and $2.4k–10k). So the model picks the job from the fixed taxonomy
// (an enum it cannot leave) and states facts from a fixed vocabulary; numbers
// are bucketed in code. Free text survives only for "other" jobs, where word
// order is ignored.

/** Fact names the key may carry. A fixed list: "length 40 ft" and "run 40 ft"
 *  must not split a cache entry. */
export const FACT_NAMES = [
  "area_sqft", "length_ft", "run_ft", "count", "capacity", "size",
  "material", "location", "stories", "access", "scope", "condition",
  "tier", "unit_owned", "permit", "trench", "panel_upgrade",
  "vehicle", "make_model",
] as const;

const TAXONOMY_IDS = [...new Set(JOB_TYPE_TAXONOMY.map((e) => e.job_type))].sort();
const TAXONOMY_LINES = JOB_TYPE_TAXONOMY
  .map((e) => `- ${e.job_type}: ${e.keywords.slice(0, 4).join(", ")}`)
  .join("\n");

const CANON_SYSTEM = `Normalize a home-service or vehicle-service request into a stable key for a \
price cache. Two requests for the same work with the same price-relevant facts \
MUST produce the identical output, however they are worded or ordered.

job_type: the ONE taxonomy job below that is this work. A repair is a repair \
job, never a replacement ("patch flat roof" is roofing.repair). Use "other" \
only when no listed job is this work (e.g. installing a sauna or hot tub).
job: the work as a short lowercase phrase "<action> <item>" with only \
price-changing qualifiers ("install owned outdoor sauna"). "owned" when the \
customer already has the unit and it is not included.
facts: only facts STATED in the request that move the price, one per name:
- area_sqft / length_ft / run_ft / count: a number ("40"); a range -> its midpoint.
- capacity: number + unit, no spaces ("9kw", "40gal", "200a").
- size, material, location (indoor / outdoor), stories, access, scope \
(patch / partial / full), condition, tier (budget / mid / premium), \
unit_owned (yes / no), permit / trench / panel_upgrade (yes / no / unknown), \
vehicle (car / truck / motorcycle), make_model: one or two lowercase words.
"Not sure" = "unknown". Never invent a fact.

Taxonomy (job_type: example words):
${TAXONOMY_LINES}`;

const CANON_SCHEMA = {
  type: "object",
  properties: {
    job_type: { type: "string", enum: [...TAXONOMY_IDS, "other"] },
    job: { type: "string" },
    facts: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string", enum: [...FACT_NAMES] },
          value: { type: "string" },
        },
        required: ["name", "value"],
        additionalProperties: false,
      },
    },
  },
  required: ["job_type", "job", "facts"],
  additionalProperties: false,
} as const;

/** Bucket edges for numeric facts: values inside one bucket share a price. */
const BUCKETS: Record<string, number[]> = {
  area_sqft: [25, 50, 100, 200, 400, 800, 1500, 3000],
  length_ft: [5, 10, 25, 50, 100, 200],
  run_ft: [10, 25, 50, 100, 200],
  count: [1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 40],
};

/** One fact as its key token: numeric facts bucketed, the rest normalized. */
export function factToken(fact: string): string {
  const f = fact.trim().toLowerCase().replace(/\s+/g, " ");
  const sp = f.indexOf(" ");
  const name = sp < 0 ? f : f.slice(0, sp);
  const value = sp < 0 ? "" : f.slice(sp + 1);
  const edges = BUCKETS[name];
  const num = value.match(/\d+(?:\.\d+)?/);
  if (edges && num) {
    const n = Number(num[0]);
    const i = edges.findIndex((e) => n <= e);
    return `${name}:${i < 0 ? `>${edges[edges.length - 1]}` : `<=${edges[i]}`}`;
  }
  return `${name}:${value.replace(/\s+/g, "")}`;
}

/** For a taxonomy job, only these facts split the cache: the job type already
 *  carries the descriptive part ("patch", "flat", the material), and letting
 *  the model's optional extras into the key split "Patch flat roof" from
 *  "Patch my flat roof" into two AI runs (2026-10-03). "other" jobs keep all
 *  facts — there the facts are the only description of the job. */
const KEY_FACTS_FOR_TAXONOMY = new Set([
  "area_sqft", "length_ft", "run_ft", "count", "capacity", "stories",
  "location", "tier", "unit_owned", "permit", "trench", "panel_upgrade",
  "vehicle", "make_model",
]);

export function canonicalKey(c: CanonicalJob): string {
  const isTaxonomy = !!c.jobType && c.jobType !== "other";
  // A taxonomy job keys on its id; an "other" job on its words, order-free.
  const job = isTaxonomy
    ? c.jobType!
    : [...new Set(c.job.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean))].sort().join(" ");
  const facts = [...new Set(
    c.facts
      .map(factToken)
      // "unknown" says nothing: it must not split from a request that omits it.
      .filter((t) => !t.endsWith(":") && !t.endsWith(":unknown"))
      .filter((t) => !isTaxonomy || KEY_FACTS_FOR_TAXONOMY.has(t.slice(0, t.indexOf(":")))),
  )].sort();
  return [job, ...facts].join("|").slice(0, 280);
}

export async function canonicalize(description: string, apiKey: string): Promise<CanonicalJob | null> {
  try {
    const r = await client(apiKey, 8_000).messages.create({
      model: MODEL,
      max_tokens: 300,
      thinking: { type: "disabled" },
      system: [{ type: "text", text: CANON_SYSTEM, cache_control: { type: "ephemeral" } }],
      output_config: { format: { type: "json_schema", schema: CANON_SCHEMA } },
      messages: [{ role: "user", content: description.slice(0, 1200) }],
    });
    const o = JSON.parse(textOf(r)) as {
      job_type?: unknown; job?: unknown; facts?: Array<{ name?: unknown; value?: unknown }>;
    };
    if (typeof o.job !== "string" || !o.job.trim() || !Array.isArray(o.facts)) return null;
    const jobType = typeof o.job_type === "string" && (o.job_type === "other" || TAXONOMY_IDS.includes(o.job_type))
      ? o.job_type
      : "other";
    const facts = o.facts
      .filter((f) => typeof f?.name === "string" && typeof f?.value === "string" && String(f.value).trim())
      .map((f) => `${String(f.name)} ${String(f.value).trim().toLowerCase()}`);
    return { jobType, job: o.job, facts };
  } catch (err) {
    console.error("pricing: canonicalize failed", String(err).slice(0, 200));
    return null;
  }
}

// ── 2/3. itemize (knowledge or web-searched) ────────────────────────────────

export type ItemizeKind = "home" | "auto" | "moto";

export function itemizeSystem(locationLabel: string, searched: boolean, kind: ItemizeKind = "home"): string {
  const who = kind === "home"
    ? ["a home-service job for a homeowner", "a licensed contractor, all-in (labor + materials +\npermit)"]
    : kind === "moto"
    ? ["a motorcycle service/repair job for a rider", "an independent motorcycle shop, all-in (parts +\nlabor + shop fees)"]
    : ["a car/truck service/repair job for a driver", "an independent repair or body shop, all-in (parts +\nlabor + shop fees)"];
  return [
    `You price ${who[0]} in ${locationLabel}: what they`,
    `would typically pay ${who[1]}, for the WHOLE job as described.`,
    "",
    searched
      ? "First use web_search (at most 2 searches) for CURRENT cost data for this job and its main components in or near this area — cost guides and local contractor pricing. Then price from that evidence."
      : "Price from your knowledge of current typical costs in this area.",
    "",
    "List the COMPONENTS of the work — every distinct piece that is billed",
    kind === "home"
      ? "(e.g. permit; new 240V circuit; wire run / trenching; disconnect; equipment\nplacement and assembly; base or pad; haul-away; finish work). For each:"
      : "(e.g. parts; labor hours at shop rate; diagnostic; fluids/consumables;\nalignment or programming; disposal / shop fees). For each:",
    "low / typical / high in whole dollars for this area, and certain=false when",
    "the request marks it maybe / possible / unknown.",
    "",
    "Rules:",
    "- Price exactly the stated scope; do not add work the request doesn't imply.",
    "- Equipment the homeowner buys separately from a retailer (sauna, hot tub,",
    "  spa, EV charger, appliance): \"install\" = installation only, never the",
    "  unit, unless the request says to supply it. \"(unit already purchased, not",
    "  included)\" always means exclude it. Contractor-supplied equipment (water",
    "  heater, furnace, AC, panel, fixtures) is priced WITH the unit.",
    "- A small repair is still a real visit: include the minimum service charge.",
    "- At most 6 components, each named in 5 words or fewer; fold small items",
    "  into the nearest component. (Output length is the user's wait.)",
    "- basis: one short line (under 20 words) naming what drives the range.",
    "Answer with ONLY the JSON object described.",
  ].join("\n");
}

const ITEM_SCHEMA = {
  type: "object",
  properties: {
    components: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          low: { type: "number" },
          typical: { type: "number" },
          high: { type: "number" },
          certain: { type: "boolean" },
        },
        required: ["name", "low", "typical", "high", "certain"],
        additionalProperties: false,
      },
    },
    basis: { type: "string" },
  },
  required: ["components", "basis"],
  additionalProperties: false,
} as const;

/** Sum components into a band. Certain parts count fully. An uncertain part
 *  (may not be needed) adds half its typical to typical and its TYPICAL — not
 *  its worst case — to high: stacking every "maybe" at its worst case made an
 *  outdoor sauna read $2.4k–10k (2026-10-03). Exported for tests. */
export function sumComponents(components: Component[]): { low: number; typical: number; high: number } {
  let low = 0, typical = 0, high = 0;
  for (const c of components) {
    const lo = Math.min(c.low, c.typical, c.high);
    const hi = Math.max(c.low, c.typical, c.high);
    const ty = Math.min(Math.max(c.typical, lo), hi);
    if (c.certain) {
      low += lo;
      typical += ty;
      high += hi;
    } else {
      typical += ty / 2;
      high += ty;
    }
  }
  const round = (v: number) => (v >= 1000 ? Math.round(v / 50) * 50 : Math.round(v / 5) * 5);
  return { low: round(low), typical: round(typical), high: round(high) };
}

/** Validate the model's JSON into components; drops malformed rows. */
export function parseComponents(raw: unknown): Component[] {
  const arr = (raw as { components?: unknown })?.components;
  if (!Array.isArray(arr)) return [];
  const out: Component[] = [];
  for (const c of arr) {
    const o = c as Record<string, unknown>;
    const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : NaN);
    const low = n(o.low), typical = n(o.typical), high = n(o.high);
    if (typeof o.name !== "string" || ![low, typical, high].every(Number.isFinite)) continue;
    if (high <= 0) continue;
    out.push({ name: o.name.slice(0, 80), low, typical, high, certain: o.certain !== false });
  }
  return out.slice(0, 15);
}

/** The model's last JSON object in free text (the searched path can't use
 *  structured output alongside server tools reliably). */
function lastJson(text: string): unknown {
  const start = text.lastIndexOf('{"components"');
  const candidates = start >= 0 ? [text.slice(start)] : [];
  const m = text.match(/\{[\s\S]*\}/);
  if (m) candidates.push(m[0]);
  for (const c of candidates) {
    for (let end = c.length; end > 1; end = c.lastIndexOf("}", end - 2) + 1) {
      try { return JSON.parse(c.slice(0, end)); } catch { /* shrink */ }
      if (end <= 0) break;
    }
  }
  return null;
}

export async function itemize(
  description: string,
  locationLabel: string,
  apiKey: string,
  searched: boolean,
  searchTool = SEARCH_TOOL,
  kind: ItemizeKind = "home",
): Promise<ItemizedEstimate | null> {
  const system = itemizeSystem(locationLabel, searched, kind);
  const user = `Job: ${description.slice(0, 1500)}`;
  try {
    let components: Component[] = [];
    let basis = "";
    if (!searched) {
      const r = await client(apiKey, 15_000).messages.create({
        model: MODEL,
        max_tokens: 1200,
        thinking: { type: "disabled" },
        system,
        output_config: { format: { type: "json_schema", schema: ITEM_SCHEMA } },
        messages: [{ role: "user", content: user }],
      });
      const o = JSON.parse(textOf(r));
      components = parseComponents(o);
      basis = typeof o.basis === "string" ? o.basis : "";
    } else {
      const c = client(apiKey, 90_000);
      const tools = [{ type: searchTool, name: "web_search", max_uses: 2 }];
      const messages: Anthropic.MessageParam[] = [{
        role: "user",
        content: `${user}\n\nAfter searching, reply with ONLY: {"components":[{"name":"…","low":0,"typical":0,"high":0,"certain":true}],"basis":"…"}`,
      }];
      let r = await c.messages.create({
        model: MODEL, max_tokens: 2500, system,
        // deno-lint-ignore no-explicit-any
        tools: tools as any, messages,
      });
      let guard = 0;
      while (r.stop_reason === "pause_turn" && guard++ < 4) {
        messages.push({ role: "assistant", content: r.content });
        r = await c.messages.create({
          model: MODEL, max_tokens: 2500, system,
          // deno-lint-ignore no-explicit-any
          tools: tools as any, messages,
        });
      }
      const o = lastJson(textOf(r)) as { basis?: unknown } | null;
      if (!o) lastItemizeError = `no json; stop=${r.stop_reason}; text=${textOf(r).slice(-300)}`;
      components = parseComponents(o);
      basis = typeof o?.basis === "string" ? o.basis : "";
    }
    if (components.length === 0) return null;
    const sum = sumComponents(components);
    if (!(sum.low > 0 && sum.low <= sum.typical && sum.typical <= sum.high)) return null;
    if (sum.high > 500_000 || sum.low < 40) return null;
    return { ...sum, basis: basis.slice(0, 200), components, searched };
  } catch (err) {
    lastItemizeError = String(err).slice(0, 500);
    console.error(`pricing: itemize (${searched ? "searched" : "knowledge"}) failed`, lastItemizeError);
    return null;
  }
}
