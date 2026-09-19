-- Caches web-search-grounded cost bands for the `pricing` Edge Function.
--
-- When the in-house engine has no modelled entry for a described job (whole-room
-- remodels — "full gut remodel of my bathroom" — have no priced taxonomy entry),
-- the function falls back to a web-search-grounded band: one Opus call with the
-- web_search tool returns a typical local low/typical/high, shown as a wide,
-- low-confidence estimate rather than a blank "get 3 bids".
--
-- That call is the most expensive path in the function (Opus + web search), so
-- it is cached per (normalized description + ZIP). Remodel costs move slowly, so
-- the TTL is long (7 days, enforced in code via created_at) — a unique phrasing
-- costs one grounded call, not one per request.
--
-- A miss (the model found nothing usable, or the band failed the sanity
-- guardrail) is NOT cached: unlike a classification "none", a transient search
-- failure shouldn't pin "no estimate" for a week.

create table if not exists public.grounded_estimate_cache (
    cache_key   text primary key,
    low         numeric not null,
    typical     numeric not null,
    high        numeric not null,
    basis       text,
    created_at  timestamptz not null default now()
);

-- Only the Edge Function (service role, bypasses RLS) touches this table;
-- RLS on with no policies keeps it inaccessible to anon/publishable clients,
-- matching classification_cache and the other pricing caches.
alter table public.grounded_estimate_cache enable row level security;
