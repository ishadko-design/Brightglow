-- Caches SerpApi Home Depot material lookups for the `pricing` Edge
-- Function. Each lookup costs SerpApi quota, so results are reused for 24h
-- per (job_type, width_in) pair rather than re-queried on every request.

create table if not exists public.materials_cache (
    cache_key   text primary key,
    materials   jsonb       not null,
    created_at  timestamptz not null default now()
);

-- Only the Edge Function (service role, which bypasses RLS) touches this table;
-- enabling RLS with no policies keeps it inaccessible to anon/publishable clients.
alter table public.materials_cache enable row level security;
