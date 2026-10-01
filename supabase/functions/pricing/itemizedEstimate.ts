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
  job: string;
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

const CANON_SYSTEM = `Normalize a home-service request into a stable key for a \
price cache. Two requests for the same work with the same price-relevant facts \
MUST produce the identical output.

job: the work as a short lowercase noun phrase in a fixed form: \
"<action> <item>" — action is one of install, replace, repair, remodel, \
build, remove, paint, clean, inspect; then the item with only the qualifiers \
that change the price (e.g. "install owned outdoor sauna", "replace 40 gal gas \
water heater", "repair leaking kitchen faucet", "remodel bathroom"). \
"Owned" when the customer already has the unit and it is not included.
facts: only facts STATED in the request that move the price, each lowercase \
"<name> <value>" with units normalized: sizes ("area 200 sq ft", "run 25-60 \
ft"), capacities ("heater 9 kw", "panel 200a"), counts ("count 3"), \
location ("outdoor"), scope flags ("trench maybe", "permit yes"), finish \
tier ("tier mid-range"). Unknown/"not sure" items: "<name> unknown". Never \
invent a fact. Sorted, no duplicates.`;

const CANON_SCHEMA = {
  type: "object",
  properties: {
    job: { type: "string" },
    facts: { type: "array", items: { type: "string" } },
  },
  required: ["job", "facts"],
  additionalProperties: false,
} as const;

export function canonicalKey(c: CanonicalJob): string {
  const facts = [...new Set(c.facts.map((f) => f.trim().toLowerCase()).filter(Boolean))].sort();
  return [c.job.trim().toLowerCase().replace(/\s+/g, " "), ...facts].join("|").slice(0, 280);
}

export async function canonicalize(description: string, apiKey: string): Promise<CanonicalJob | null> {
  try {
    const r = await client(apiKey, 8_000).messages.create({
      model: MODEL,
      max_tokens: 200,
      thinking: { type: "disabled" },
      system: [{ type: "text", text: CANON_SYSTEM, cache_control: { type: "ephemeral" } }],
      output_config: { format: { type: "json_schema", schema: CANON_SCHEMA } },
      messages: [{ role: "user", content: description.slice(0, 1200) }],
    });
    const o = JSON.parse(textOf(r)) as CanonicalJob;
    if (typeof o.job !== "string" || !o.job.trim() || !Array.isArray(o.facts)) return null;
    return { job: o.job, facts: o.facts.filter((f) => typeof f === "string") };
  } catch (err) {
    console.error("pricing: canonicalize failed", String(err).slice(0, 200));
    return null;
  }
}

// ── 2/3. itemize (knowledge or web-searched) ────────────────────────────────

export function itemizeSystem(locationLabel: string, searched: boolean): string {
  return [
    `You price a home-service job for a homeowner in ${locationLabel}: what they`,
    "would typically pay a licensed contractor, all-in (labor + materials +",
    "permit), for the WHOLE job as described.",
    "",
    searched
      ? "First use web_search (at most 2 searches) for CURRENT cost data for this job and its main components in or near this area — cost guides and local contractor pricing. Then price from that evidence."
      : "Price from your knowledge of current typical costs in this area.",
    "",
    "List the COMPONENTS of the work — every distinct piece that is billed",
    "(e.g. permit; new 240V circuit; wire run / trenching; disconnect; equipment",
    "placement and assembly; base or pad; haul-away; finish work). For each:",
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
    "- basis: one short line naming what drives the range.",
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

/** Sum components into a band. Certain parts count fully; uncertain parts add
 *  to high and half to typical (they may not happen). Exported for tests. */
export function sumComponents(components: Component[]): { low: number; typical: number; high: number } {
  let low = 0, typical = 0, high = 0;
  for (const c of components) {
    const lo = Math.min(c.low, c.typical, c.high);
    const hi = Math.max(c.low, c.typical, c.high);
    const ty = Math.min(Math.max(c.typical, lo), hi);
    if (c.certain) {
      low += lo;
      typical += ty;
    } else {
      typical += ty / 2;
    }
    high += hi;
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
): Promise<ItemizedEstimate | null> {
  const system = itemizeSystem(locationLabel, searched);
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
