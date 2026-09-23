-- Caches LLM price estimates for the `pricing` Edge Function (llmEstimate.ts).
-- The model prices only requests the in-house catalog can't; caching per
-- (zip3 region, vehicle, category, normalized description) makes repeat
-- searches free and keeps latency flat. low/typical/high are null when the
-- model declined — that outcome is cached too, so unpriceable text doesn't
-- re-trigger a call on every retry.

create table if not exists public.price_estimate_cache (
    cache_key   text primary key,
    low         double precision,
    typical     double precision,
    high        double precision,
    created_at  timestamptz not null default now()
);

-- Only the Edge Function (service role, which bypasses RLS) touches this table;
-- enabling RLS with no policies keeps it inaccessible to anon/publishable clients.
alter table public.price_estimate_cache enable row level security;
