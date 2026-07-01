-- Phase 2: cache Places Text Search responses so one search per area/category/day
-- serves everyone, instead of billing Google on every visit.
--
-- Keyed by "textQuery | lat-bucket | lng-bucket | pageSize | day" (built in the
-- Edge Function). We store Google's raw response blob and reuse it within the TTL.

create table if not exists public.search_cache (
    cache_key   text primary key,
    response    jsonb       not null,
    created_at  timestamptz not null default now()
);

-- Only the Edge Function (service role, which bypasses RLS) touches this table;
-- enabling RLS with no policies keeps it inaccessible to anon/publishable clients.
alter table public.search_cache enable row level security;
