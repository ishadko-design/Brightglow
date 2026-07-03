-- Caches SF DBI permit query results for the `pricing` Edge Function so a
-- repeat lookup for the same job_type/keyword window within 24h doesn't
-- re-hit data.sfgov.org. Edge Functions are stateless per invocation, so an
-- in-memory cache (fine in a long-running server) doesn't survive between
-- requests here — Postgres does.

create table if not exists public.permit_cache (
    cache_key   text primary key,
    permits     jsonb       not null,
    created_at  timestamptz not null default now()
);

-- Only the Edge Function (service role, which bypasses RLS) touches this table;
-- enabling RLS with no policies keeps it inaccessible to anon/publishable clients.
alter table public.permit_cache enable row level security;
