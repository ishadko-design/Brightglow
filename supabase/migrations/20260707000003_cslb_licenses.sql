-- CSLB (California Contractors State License Board) license master.
--
-- Source: the free, unauthenticated Public Data Portal export —
--   https://www.cslb.ca.gov/OnlineServices/DataPortal/DownLoadFile.ashx?fName=MasterLicenseData&type=C
-- ~243k rows, refreshed by `scripts/import-cslb.ts` (see that file for cadence).
-- The export already excludes cancelled / revoked / expired-non-renewable
-- licenses, but it DOES include suspended ones (bond, workers' comp, judgement
-- …) and expired-but-renewable ones — so "present in this table" does NOT mean
-- "in good standing". `is_active` below is the only thing the app may trust.
--
-- Businesses are matched to a license by PHONE, not name: 99.9% of CSLB rows
-- carry a 10-digit business phone, and Google Places returns
-- `nationalPhoneNumber` for the same business. An exact match on the normalized
-- digits avoids fuzzy name/address matching entirely.

create table if not exists public.cslb_licenses (
    license_no      text primary key,
    business_name   text not null,
    -- Normalized to exactly 10 digits by the importer; null when CSLB has none.
    phone           text,
    city            text,
    zip             text,
    -- Raw CSLB values, kept so the badge's meaning can be tightened later
    -- (e.g. requiring a C36 plumbing classification for a plumbing search).
    primary_status  text,
    classifications text,
    expiration_date date,
    -- Precomputed: CLEAR status (not suspended) and not past expiry. This is the
    -- single predicate the badge is allowed to depend on, so "Licensed" can
    -- never be shown for a suspended or lapsed license.
    is_active       boolean not null default false,
    updated_at      timestamptz not null default now()
);

-- The app's only query shape: "which of these phone numbers hold an active
-- license?" Partial index — rows without a phone are unmatchable by definition.
create index if not exists cslb_licenses_active_phone_idx
    on public.cslb_licenses (phone)
    where phone is not null and is_active;

-- Public record data (Business & Professions Code § 7124.6), so reads are open.
-- Writes are service-role only: the importer bypasses RLS, and no policy grants
-- insert/update/delete to anon or authenticated.
alter table public.cslb_licenses enable row level security;

drop policy if exists "cslb_licenses public read" on public.cslb_licenses;
create policy "cslb_licenses public read"
    on public.cslb_licenses
    for select
    to anon, authenticated
    using (true);
