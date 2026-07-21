-- Cache of photos discovered on a business's OWN website, keyed by Google
-- place_id. Populated on demand by the `business-photos` Edge Function the first
-- time anyone opens that business's gallery, then reused by every later viewer —
-- so the external website fetch happens ONCE per business, not once per
-- gallery-open. This is the "don't over-call" fan-in: the client only ever hits
-- our own function, which serves this cache.
--
-- We store the source image URLs (the business's own hosted images), never
-- re-hosted bytes — it's their content on their public site, and linking avoids
-- both storage cost and a re-distribution copy.
create table if not exists public.business_website_photos (
    place_id    text primary key,                 -- = Google place_id (Contractor.id)
    website     text,                              -- the site we scraped
    photos      jsonb  not null default '[]',      -- [{ "url": text, "w": int, "h": int }]
    ok          boolean not null default false,    -- did the fetch find usable photos
    fetched_at  timestamptz not null default now() -- drives the TTL refresh
);

-- Only the service-role Edge Function touches this table (clients go through the
-- function, never PostgREST), so RLS on with no policies = deny by default for
-- anon/authenticated, while the service role still bypasses it.
alter table public.business_website_photos enable row level security;
