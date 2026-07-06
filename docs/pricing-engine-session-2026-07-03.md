# Home pricing engine — session summary (2026-07-03)

Compact handoff for a fresh conversation. Full technical detail lives in Claude's
memory (`home-pricing-engine.md`, `auto-moto-vertical.md`, `places-search-relevance.md`),
auto-loaded in this project's Claude Code sessions — this file is the portable version.

## What was built

**Home pricing engine** — replaces fake "$100-250" estimates with real SF DBI permit
data + retail materials (SerpApi/Home Depot).

- Live: `supabase/functions/pricing/` (Deno Edge Function) + `Brightglow/Models/PricingService.swift`
- Reference/tested: `pricing-engine/` (Node package, documents the formula)
- **Formula**: `all_in = (materials_floor × 0.9–1.3) + max(permit_p25×1.2 − materials, $600)`
  to `(materials×1.3) + (permit_p75×1.2 − materials)`
- **Permit-only fallback**: if materials pricing unavailable, shows the buffered permit
  range alone, labeled "permit data only" — real data beats no number
- **7 covered job_types**: `bathroom.vanity`, `bathroom.full`, `plumbing.water_heater`,
  `electrical.panel`, `hvac.furnace`, `windows_doors.window`, `carpentry.deck`
- **4 categories structurally uncoverable** by this formula: Painting, Flooring,
  Landscaping, Pest Control — they don't generate SF permits at all (same root problem
  as auto/moto)

## Removed entirely (all "looked confident, wasn't verifiable")

1. LLM-guessed price estimate (Hugging Face/Qwen completion)
2. A review-derived price range — caught live showing identical noisy numbers
   ("$35–700") on every card in a list; regex-extracted dollar mentions from reviews
   can't distinguish job cost from tips/discounts
3. Static per-category canned price tiers (the original "$100-250")

**Current rule, app-wide**: every price line is either real pricing-engine data or
`"N businesses nearby — price estimate coming soon"`. No guessing anywhere.

## Data-quality bugs found only by verifying against live SF data (not unit tests)

- Naive keyword matching pulled bundled-scope permits into narrow-job datasets (a
  $95K kitchen remodel counted as a $95K water heater job) → fixed with
  `excludeIfContains` bigger-scope signal words
- **SF permit revisions/amendments carry $1 placeholder valuations** — up to 12% of
  matched permits for some job types. Fixed with pattern exclusion + $100 floor.
- Legalization/code-enforcement permits ("comply with NOV") bundle inspection-driven
  scope — added to exclusions
- 1.5×IQR outlier trim as a statistical safety net
- **Standing practice now**: verify any permit-matching change against live SF Open
  Data (free, no auth) before considering it done — every bug above was invisible in
  unit tests

## Other fixes this session

- **Places search relevance**: Google Text Search was surfacing unrelated businesses
  (dentists) for trade searches — fixed with a non-trade type blocklist (deliberately
  not an allowlist, to keep "any item searchable" intact)
- **Photo-derived detail**: vision LLM (already used for category routing) now also
  extracts visible attributes (size/capacity/material) in the same call, threaded into
  the pricing request only (never the business search) to narrow the permit match

## Researched but not committed to

- **Craftsman National Estimator API** — inquiry submitted (via `help@brightglow.co`),
  awaiting reply/sandbox key. Best fit if labor+material per unit is wanted directly
  (would also unlock Painting/Landscaping, which permits structurally can't)
- **Shovels.ai** — national permit API (85% US, 2,450+ jurisdictions), self-serve,
  $599/mo — the answer if/when scaling this beyond SF
- Walmart Open API — turned out to need Impact Radius affiliate approval, not truly
  self-serve as first thought

## Blocking issue — nothing shows live yet

**`SERPAPI_KEY` still isn't set.** Get one at serpapi.com (free tier: 100/mo), then
`supabase secrets set SERPAPI_KEY=...`. No redeploy needed.

## Immediate next step

Set `SERPAPI_KEY` to see real numbers live. Everything else is deployed and tested.
