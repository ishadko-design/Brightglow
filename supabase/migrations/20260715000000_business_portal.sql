-- Self-serve business portal (web CRM at brightglow.co/business).
--
-- Identity is the SAME model as chat (see 20260709000000_chat.sql): a business
-- is not a special account type — it's an authenticated user whose OTP-verified
-- email matches a lead's contractor_email. That possession is the claim. So the
-- portal needs no bespoke auth: a signed-in business edits exactly the rows whose
-- place_id appears on a lead addressed to their email.
--
-- Unlike chat (writes routed through the LeadBridge service role so an offline
-- party still gets the email relay), a profile edit has no side effect — so these
-- writes go DIRECT from the browser via PostgREST/Storage, gated by the RLS below.
-- No Edge Function in the write path.

-- ── ownership helper ───────────────────────────────────────────────────────
-- True iff the caller's verified JWT email is the contractor_email on some lead
-- for this place_id. SECURITY DEFINER so it reads `leads` regardless of the
-- caller's own row access (same shape as public.is_lead_participant). This is the
-- single gate every profile / photo write policy leans on.
create or replace function public.owns_business(p_place_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
    from public.leads l
    where l.place_id = p_place_id
      and lower(l.contractor_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$fn$;

revoke all on function public.owns_business(text) from public;
grant execute on function public.owns_business(text) to authenticated;

-- ── business_profiles ──────────────────────────────────────────────────────
-- The claimable, business-edited record. Keyed by place_id — the same join key
-- business_enrichment and business-logos already use — so a profile LAYERS OVER
-- the Google-derived enrichment (it never mutates it). Anything left null falls
-- back to the enriched/Places value in the app.
create table if not exists public.business_profiles (
  place_id          text primary key,
  display_name      text,
  tagline           text,
  about             text,
  phone             text,
  website           text,
  -- Services with indicative price ranges, business-authored. Shape:
  --   [{ "name": "Drain cleaning", "price_min": 100, "price_max": 250, "unit": "job" }]
  -- unit is free text ("job", "hour", "sq ft", "visit"); price_* are nullable
  -- (a service can be "call for quote").
  services          jsonb  not null default '[]'::jsonb,
  service_area      text,                 -- free text or ZIP list, business-authored
  license_number    text,
  insured           boolean not null default false,
  years_in_business int,
  accepting_work    boolean not null default true,
  -- Ordered object paths in the business-photos bucket ("<place_id>/<uuid>.jpg").
  photos            jsonb  not null default '[]'::jsonb,
  logo_path         text,                 -- overrides the auto-resolved logo when set
  updated_at        timestamptz not null default now(),
  created_at        timestamptz not null default now()
);

alter table public.business_profiles enable row level security;

-- Public READ: the profile is shown to customers browsing, so anon + authed can
-- select any row. (Only safe, business-authored fields live here — no PII.)
grant select on public.business_profiles to anon, authenticated;
drop policy if exists "profiles are public" on public.business_profiles;
create policy "profiles are public"
  on public.business_profiles
  for select
  to anon, authenticated
  using (true);

-- Owner WRITE: insert/update only rows for a place_id the caller owns. `with
-- check` on both guards against inserting or renaming into someone else's key.
grant insert, update on public.business_profiles to authenticated;

drop policy if exists "owner can insert own profile" on public.business_profiles;
create policy "owner can insert own profile"
  on public.business_profiles
  for insert
  to authenticated
  with check (public.owns_business(place_id));

drop policy if exists "owner can update own profile" on public.business_profiles;
create policy "owner can update own profile"
  on public.business_profiles
  for update
  to authenticated
  using (public.owns_business(place_id))
  with check (public.owns_business(place_id));

-- Keep updated_at honest on every edit.
create or replace function public.touch_business_profile()
returns trigger
language plpgsql
as $fn$
begin
  new.updated_at = now();
  return new;
end;
$fn$;

drop trigger if exists trg_touch_business_profile on public.business_profiles;
create trigger trg_touch_business_profile
  before update on public.business_profiles
  for each row execute function public.touch_business_profile();

-- ── business-photos storage bucket ─────────────────────────────────────────
-- Public read (the app gallery loads straight from the CDN URL, like logos).
-- Writes are gated by the same owns_business() check, keyed on the first path
-- segment ("<place_id>/..."), so a business can only touch its own folder.
insert into storage.buckets (id, name, public)
values ('business-photos', 'business-photos', true)
on conflict (id) do nothing;

drop policy if exists "business photos public read" on storage.objects;
create policy "business photos public read"
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'business-photos');

drop policy if exists "owner writes own business photos" on storage.objects;
create policy "owner writes own business photos"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'business-photos'
    and public.owns_business(split_part(name, '/', 1))
  );

drop policy if exists "owner updates own business photos" on storage.objects;
create policy "owner updates own business photos"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'business-photos'
    and public.owns_business(split_part(name, '/', 1))
  )
  with check (
    bucket_id = 'business-photos'
    and public.owns_business(split_part(name, '/', 1))
  );

drop policy if exists "owner deletes own business photos" on storage.objects;
create policy "owner deletes own business photos"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'business-photos'
    and public.owns_business(split_part(name, '/', 1))
  );

-- ── email_suppressions (CAN-SPAM) ──────────────────────────────────────────
-- One row per address that must NOT be emailed. The LeadBridge mailer checks
-- this table before every send and honors a one-click unsubscribe (List-
-- Unsubscribe header + link) by inserting here. `token` backs the unauthenticated
-- unsubscribe URL so a recipient can opt out without logging in.
--
-- Written and read by the LeadBridge service role only; no anon/authenticated
-- grants (RLS on, no policies => clients can't read the suppression list).
create table if not exists public.email_suppressions (
  email       text primary key,
  reason      text not null default 'unsubscribe',  -- 'unsubscribe' | 'bounce' | 'complaint'
  token       text unique,                          -- opaque id embedded in the unsubscribe link
  created_at  timestamptz not null default now()
);

alter table public.email_suppressions enable row level security;
-- Deliberately no grants/policies: only the service role (which bypasses RLS)
-- touches this table.
