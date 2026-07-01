-- Phase 3: shared photo-screening verdicts.
--
-- The FIRST user to view a place screens its photos on-device (Apple Vision) and
-- uploads which ones are real work shots; every other user (any device) reuses
-- that verdict and skips screening — so a place's photo pool is downloaded for
-- classification at most once across all users (until the 30-day refresh).
--
-- Keyed by (place_id, vertical) because screening differs by vertical: Auto & moto
-- keeps vehicle shots that Home rejects.

create table if not exists public.place_verdicts (
    place_id    text        not null,
    vertical    text        not null,           -- "home" | "auto"
    kept        jsonb       not null,           -- array of kept photo URLs ([] = no work photos)
    scanned     int         not null,           -- how many source photos were screened
    screened_at timestamptz not null default now(),
    primary key (place_id, vertical)
);

-- Only the Edge Function (service role, bypasses RLS) reads/writes this table.
alter table public.place_verdicts enable row level security;
