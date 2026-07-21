-- Contractor logo, resolved once per business and hosted in the public
-- `business-logos` Storage bucket. Same eventually-consistent, resolve-once
-- pattern as the other business_enrichment columns: the first lookup that has a
-- website resolves + normalizes + uploads the logo, and every subsequent lookup
-- for that place_id reuses the row instead of re-resolving.
--
-- `logo_source = 'none'` is the NEGATIVE cache: the business was checked and no
-- usable logo was found (no website, or every source failed). It must be set on
-- a miss so we don't re-run the resolve chain on every future lookup — the
-- single biggest cost lever here, since many small contractors have no logo.
-- The client draws a name monogram in that case (no image is stored).

alter table public.business_enrichment
    add column if not exists logo_path       text,        -- object path in the public bucket, NULL when no logo
    add column if not exists logo_source     text,        -- 'og_scrape' | 'favicon' | 'brandfetch' | 'none'
    add column if not exists logo_checked_at timestamptz; -- set on both hit and miss; presence => don't re-resolve

-- Public, read-only bucket for normalized logos (256px WebP, ~10KB each).
-- Public so the client loads them straight from the CDN URL (cache-friendly,
-- no per-request signing) rather than proxying through an Edge Function.
-- Only the resolver (service role) writes; anon may read.
insert into storage.buckets (id, name, public)
values ('business-logos', 'business-logos', true)
on conflict (id) do nothing;
