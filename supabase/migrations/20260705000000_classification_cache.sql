-- Caches LLM job-type classifications for the `pricing` Edge Function.
-- The Claude fallback classifier (llmClassifier.ts) only runs when keyword
-- matching misses; caching per normalized (category, description) makes
-- repeat phrasings free and keeps latency flat. job_type is null when the
-- model answered "none" — that outcome is cached too, so unmatchable text
-- doesn't re-trigger a call on every retry.

create table if not exists public.classification_cache (
    cache_key   text primary key,
    job_type    text,
    created_at  timestamptz not null default now()
);

-- Only the Edge Function (service role, which bypasses RLS) touches this table;
-- enabling RLS with no policies keeps it inaccessible to anon/publishable clients.
alter table public.classification_cache enable row level security;
