-- Phone-first business identity for the /biz claim/sign-in hub.
--
-- Until now a business was identified ONLY by an OTP-verified email that matched
-- a lead's contractor_email (see 20260715000000_business_portal.sql /
-- 20260709000000_chat.sql). But the primary channel we reach a business on is the
-- P2P TEXT — the customer texts the business's phone from their own Messages app —
-- and ~70% of those businesses have no email we can resolve. Such a business
-- tapping "claim" at brightglow.co/biz hit a dead end ("no business matched").
--
-- Fix: make the OTP-verified PHONE a first-class identity, exactly parallel to the
-- email one. We record the texted phone on the lead, and let a business prove
-- possession of that number via Supabase phone OTP. The JWT then carries `phone`,
-- and the three ownership predicates below match on email OR phone OR an explicit
-- owner link — so phone sign-in surfaces a business's requests through the SAME
-- RLS paths email already uses. No parallel data path, no bespoke auth.
--
-- Columns live canonically in leadbridge/sql/schema.sql (the leads / business_places
-- tables are owned there); the `add column if not exists` here is defensive so this
-- migration compiles even if applied before `npm run db:migrate`.

alter table public.leads            add column if not exists contractor_phone text;
alter table public.business_places  add column if not exists phone            text;
-- The Supabase user who claimed this place by verifying its phone. Anchors billing
-- and survives even if the lead-level phone data later changes.
alter table public.business_places  add column if not exists owner_user_id    uuid;

create index if not exists idx_leads_contractor_phone
  on public.leads (contractor_phone) where contractor_phone is not null;
create index if not exists idx_business_places_owner
  on public.business_places (owner_user_id) where owner_user_id is not null;

-- ── phone normalization ─────────────────────────────────────────────────────
-- Compare on the trailing 10 digits so "+1 (415) 555-1234", "14155551234" and
-- "4155551234" all match — absorbing the +1 / 1 / no-country-code inconsistency
-- between what the app sends and what Supabase puts in the JWT (digits, no '+').
-- US-only by design (the app is US-only); returns '' for anything under 10 digits
-- so a business with no phone never matches another's blank.
create or replace function public.norm_phone(p text)
returns text
language sql
immutable
as $fn$
  select case
    when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 10
    then right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
    else ''
  end;
$fn$;

-- The caller's verified phone from the JWT, normalized. Empty when the caller
-- signed in by email (no phone claim) so the phone branch can never over-match.
create or replace function public.jwt_phone()
returns text
language sql
stable
as $fn$
  select public.norm_phone(auth.jwt() ->> 'phone');
$fn$;

-- ── owns_business: email OR phone OR explicit owner link ─────────────────────
-- Supersedes the email-only version in 20260715000000_business_portal.sql. Every
-- profile / photo write policy leans on this one gate, so extending it here is all
-- that's needed for a phone-verified business to edit its listing.
create or replace function public.owns_business(p_place_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select
    exists (
      select 1 from public.leads l
      where l.place_id = p_place_id
        and lower(l.contractor_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    )
    or (
      public.jwt_phone() <> ''
      and exists (
        select 1 from public.leads l
        where l.place_id = p_place_id
          and public.norm_phone(l.contractor_phone) = public.jwt_phone()
      )
    )
    or exists (
      select 1 from public.business_places bp
      where bp.place_id = p_place_id
        and bp.owner_user_id = auth.uid()
    );
$fn$;

revoke all on function public.owns_business(text) from public;
grant execute on function public.owns_business(text) to authenticated;

-- ── is_lead_participant: same three-way match (chat threads + messages) ──────
-- Supersedes the email-only version in 20260709000000_chat.sql so a phone-verified
-- business can read the thread and messages on its leads, not just edit its profile.
create or replace function public.is_lead_participant(p_lead_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
    from public.leads l
    where l.id = p_lead_id
      and (
        l.user_id = auth.uid()
        or lower(l.contractor_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        or (public.jwt_phone() <> '' and public.norm_phone(l.contractor_phone) = public.jwt_phone())
        or exists (
          select 1 from public.business_places bp
          where bp.place_id = l.place_id and bp.owner_user_id = auth.uid()
        )
      )
  );
$fn$;

revoke all on function public.is_lead_participant(uuid) from public;
grant execute on function public.is_lead_participant(uuid) to authenticated;

-- ── leads SELECT policy: let a phone/owner match read the lead row itself ────
-- The portal lists a business's requests with a direct `from("leads").select(...)`,
-- so the row-level SELECT policy (not just the helper fns) has to admit the phone
-- and owner matches too. Mirrors the "chat participant can select lead" policy in
-- 20260709000000_chat.sql, with the two new branches appended.
drop policy if exists "chat participant can select lead" on public.leads;
create policy "chat participant can select lead"
  on public.leads
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or lower(contractor_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
    or (public.jwt_phone() <> '' and public.norm_phone(contractor_phone) = public.jwt_phone())
    or exists (
      select 1 from public.business_places bp
      where bp.place_id = leads.place_id and bp.owner_user_id = auth.uid()
    )
  );
