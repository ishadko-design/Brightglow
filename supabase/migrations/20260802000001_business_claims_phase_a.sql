-- Business claim — Phase A foundation (see BUSINESS_CLAIM_PLAN.md).
--
-- Turns the "Nothing to manage here" dead end into a real claim/create flow for
-- the two paths that need no external secrets:
--   method 1  phone_match  — the OTP-verified phone equals the Google-listed
--                            business_places.phone  -> instant verified claim
--   method 6  create       — the business isn't in the directory at all -> create
--                            a brand-new place the creator owns
--
-- The other rungs (verify-listed-phone, domain-email, license, manual review) are
-- server-side in leadbridge/ and land in Phases B–D; this migration only defines
-- the shared state (business_claims) + the ownership gate they all reuse.
--
-- Safe to apply on top of prod's email-only world: it (re)defines owns_business to
-- ALSO honour phone and an explicit owner link (parallel to the not-yet-applied
-- 20260728000000_business_phone_claim.sql), and reaches business_places only via
-- SECURITY DEFINER functions — it never enables/changes RLS on that LeadBridge table.

-- Defensive: these columns are canonically LeadBridge's (leadbridge/sql/schema.sql),
-- added here too so this migration compiles against a bare Supabase.
alter table public.business_places add column if not exists phone         text;
alter table public.business_places add column if not exists owner_user_id uuid;

-- ── phone normalization (mirror of 20260728000000) ──────────────────────────
create or replace function public.norm_phone(p text)
returns text language sql immutable as $fn$
  select case
    when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 10
    then right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
    else ''
  end;
$fn$;

create or replace function public.jwt_phone()
returns text language sql stable as $fn$
  select public.norm_phone(auth.jwt() ->> 'phone');
$fn$;

-- ── owns_business: email OR phone-on-a-lead OR explicit owner link ───────────
-- Supersedes the email-only prod version so a phone- or create-claimed owner can
-- edit its profile/photos (every write policy leans on this one gate).
create or replace function public.owns_business(p_place_id text)
returns boolean language sql stable security definer set search_path = public as $fn$
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

-- ── claims ledger ───────────────────────────────────────────────────────────
-- One row per claim attempt. Phases B–D append pending rows and a reviewer flips
-- them; Phase A only ever writes verified rows (phone_match / create).
create table if not exists public.business_claims (
  id          uuid primary key default gen_random_uuid(),
  place_id    text not null,
  user_id     uuid not null default auth.uid(),
  method      text not null check (method in
                ('phone_match','listed_phone','domain_email','license','review','create')),
  status      text not null default 'pending' check (status in
                ('pending','verified','rejected')),
  evidence    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz
);
create index if not exists idx_business_claims_place on public.business_claims (place_id);
create index if not exists idx_business_claims_user  on public.business_claims (user_id);
-- At most one live (non-rejected) claim per place, so two people can't both hold a
-- pending claim on the same listing.
create unique index if not exists uq_business_claims_live
  on public.business_claims (place_id) where status <> 'rejected';

alter table public.business_claims enable row level security;

-- A user sees only their own claims. Writes go through the SECURITY DEFINER
-- functions below (Phase A) or LeadBridge's service role (Phases B–D), so no
-- direct insert/update policy is granted here.
grant select on public.business_claims to authenticated;
drop policy if exists "own claims are visible" on public.business_claims;
create policy "own claims are visible"
  on public.business_claims for select to authenticated
  using (user_id = auth.uid());

-- ── method 1: claim by phone match ──────────────────────────────────────────
-- Sets owner_user_id when the caller's verified phone equals the listing's
-- Google number. Returns true on success, false if the phone doesn't match or the
-- place is already owned by someone else. SECURITY DEFINER so it can write the
-- LeadBridge-owned business_places without opening that table to clients.
create or replace function public.claim_business(p_place_id text)
returns boolean language plpgsql security definer set search_path = public as $fn$
declare
  v_phone text := public.jwt_phone();
  v_uid   uuid := auth.uid();
  v_owner uuid;
  v_match boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  select owner_user_id,
         (v_phone <> '' and public.norm_phone(phone) = v_phone)
    into v_owner, v_match
    from public.business_places
   where place_id = p_place_id;

  if not found then
    return false;                      -- unknown place
  end if;
  if v_owner is not null then
    return v_owner = v_uid;            -- already mine = ok (idempotent); else no
  end if;
  if not coalesce(v_match, false) then
    return false;                      -- phone doesn't match -> use a Phase B–D path
  end if;

  update public.business_places set owner_user_id = v_uid where place_id = p_place_id;

  insert into public.business_claims (place_id, user_id, method, status, evidence)
  values (p_place_id, v_uid, 'phone_match', 'verified',
          jsonb_build_object('matched_phone', v_phone));
  return true;
end;
$fn$;
revoke all on function public.claim_business(text) from public;
grant execute on function public.claim_business(text) to authenticated;

-- ── method 6: create a brand-new business ───────────────────────────────────
-- For a business not in the directory. The creator owns it outright (nothing to
-- hijack — the listing didn't exist). Returns the new place_id.
create or replace function public.create_business(p_name text, p_website text default null, p_phone text default null)
returns text language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_id  text := 'bg-' || replace(gen_random_uuid()::text, '-', '');
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'a business name is required';
  end if;

  insert into public.business_places (place_id, business_name, website, phone, owner_user_id)
  values (v_id, btrim(p_name), nullif(btrim(coalesce(p_website, '')), ''),
          nullif(btrim(coalesce(p_phone, '')), ''), v_uid);

  insert into public.business_claims (place_id, user_id, method, status)
  values (v_id, v_uid, 'create', 'verified');
  return v_id;
end;
$fn$;
revoke all on function public.create_business(text, text, text) from public;
grant execute on function public.create_business(text, text, text) to authenticated;

-- ── portal source: places I own or can claim by phone ───────────────────────
-- The portal lists businesses from leads today; this adds the second source so a
-- lead-less business still surfaces. `owned` = already mine; otherwise it's a
-- phone-match the user can one-tap claim.
create or replace function public.my_claimable_places()
returns table (place_id text, business_name text, website text, phone text, owned boolean)
language sql stable security definer set search_path = public as $fn$
  select bp.place_id, bp.business_name, bp.website, bp.phone,
         (bp.owner_user_id = auth.uid()) as owned
    from public.business_places bp
   where bp.owner_user_id = auth.uid()
      or (
        public.jwt_phone() <> ''
        and bp.owner_user_id is null
        and public.norm_phone(bp.phone) = public.jwt_phone()
      );
$fn$;
revoke all on function public.my_claimable_places() from public;
grant execute on function public.my_claimable_places() to authenticated;
