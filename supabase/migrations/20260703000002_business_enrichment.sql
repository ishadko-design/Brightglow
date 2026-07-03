-- One row per business (place_id) holding data we can't get from Google
-- Places at all: a contact email for LeadBridge outreach, license
-- verification, and a permit-derived signal for typical job size/volume.
--
-- Eventually-consistent, same pattern as place_verdicts: a business is
-- enriched once by a background job, then every subsequent lookup for that
-- place_id reuses the row instead of re-fetching. Each source has its own
-- *_checked_at so a future refresh job can re-check stale rows independently
-- (e.g. re-check licenses every 90 days without re-scraping email).

create table if not exists public.business_enrichment (
    place_id              text        primary key,

    email                 text,
    email_source          text,       -- 'website_scrape' | 'manual' | 'enrichment_api'
    email_checked_at      timestamptz,

    license_number        text,
    license_status        text,       -- 'active' | 'expired' | 'suspended' | 'not_found'
    license_checked_at    timestamptz,

    -- Derived from SF DBI permits filed under this business's name — reuses
    -- fetchSFPermitsRaw's existing `contractor` field (supabase/functions/pricing/pricingEngine.ts),
    -- just filtered by contractor name instead of job-type keyword.
    permit_count          int,
    permit_total_valuation numeric,
    permit_job_types       jsonb,     -- e.g. ["kitchen.remodel", "bathroom.vanity"]
    permit_checked_at      timestamptz,

    updated_at            timestamptz not null default now()
);

-- Only the enrichment job (service role, bypasses RLS) reads/writes this
-- table — same access pattern as search_cache / place_verdicts / permit_cache.
alter table public.business_enrichment enable row level security;
