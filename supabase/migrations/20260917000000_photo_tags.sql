-- Server-side photo tag store: vision-model tags for Google Places photos, keyed by
-- the stable photo resource name ("places/<place_id>/photos/<photo_id>"), shared
-- across ALL users and verticals.
--
-- Why this table exists: today the `phototags` VLM call runs opportunistically on
-- one user's phone (first screen of a place, cached images only, fail-silent) and
-- its tags live only in that verdict's `kept` labels for 30 days. The business
-- ranking's photo-evidence tier (+2 "did this exact work") can only fire when a
-- kept photo carries a label matching the query's subject term ("furnace"), so
-- with generic on-device labels the strongest signal almost never fires and
-- businesses lead with whatever Google returned first.
--
-- Writers:
--   - `phototags` persists every successful client-driven tag call here
--     (dedupe: one VLM call per photo name, globally, instead of per verdict).
--   - `photo` (the Places photo proxy) tags the 512px screening rendition in the
--     background on a fresh Google fetch — the bytes are already downloaded
--     server-side, so this adds no new Google billing.
-- Readers:
--   - `phototags` checks this table first and returns stored tags without
--     calling the VLM again.
--   - `verdicts` (op=get) unions stored tags into each kept photo's labels, so
--     even a stale/unenriched verdict serves rich tags the moment any path has
--     tagged its photos.
--
-- Only the Edge Functions (service role, bypasses RLS) read/write this table.

create table if not exists public.photo_tags (
    photo_name text primary key,            -- "places/<place_id>/photos/<photo_id>"
                                           -- (or a full URL for non-Places photos,
                                           --  e.g. business-website images)
    place_id   text,                       -- denormalized from the photo name, for
                                           -- debugging and backfill queries
    tags       text[] not null default '{}',
    model      text,                        -- model that produced the tags
    tagged_at  timestamptz not null default now()
);

alter table public.photo_tags enable row level security;
-- No public policies: service-role only, same pattern as place_verdicts.
