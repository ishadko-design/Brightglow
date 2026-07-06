-- Caches EstimationPro (EPCI) construction cost line items for the `pricing`
-- Edge Function. Public API has a 100 req/day per-IP rate limit, so results
-- are reused for 24h per (trade, zip-prefix) pair rather than re-queried on
-- every request — same pattern as permit_cache/materials_cache.

create table if not exists public.epci_cache (
    cache_key   text primary key,
    items       jsonb       not null,
    created_at  timestamptz not null default now()
);

-- Only the Edge Function (service role, which bypasses RLS) touches this table;
-- enabling RLS with no policies keeps it inaccessible to anon/publishable clients.
alter table public.epci_cache enable row level security;
