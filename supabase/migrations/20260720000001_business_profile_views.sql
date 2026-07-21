-- Profile views for the business dashboard's "Views" tile.
--
-- The customer doing the viewing is usually NOT signed in (browsing contractors
-- happens well before the OTP gate at quote request), so this can't be an
-- RLS-gated insert keyed on auth.uid(). It also shouldn't be: a business has no
-- business knowing WHO looked at them, only how many did.
--
-- So: no viewer identity is stored at all. Views aggregate into per-day counters
-- via a SECURITY DEFINER function that anon and authenticated may both call. The
-- daily bucket keeps the table tiny (one row per business per day) and still lets
-- the dashboard window the number ("last 30 days") rather than showing a
-- lifetime total that only ever goes up.

create table if not exists public.business_profile_views (
  place_id text not null,
  day      date not null default (now() at time zone 'utc')::date,
  views    integer not null default 0,
  primary key (place_id, day)
);

-- Owner-only read. There is no insert/update/delete policy on purpose: the only
-- write path is record_business_view() below, which is SECURITY DEFINER and so
-- bypasses RLS. A client can increment a counter; it can never set one.
alter table public.business_profile_views enable row level security;

drop policy if exists "owner reads own view counts" on public.business_profile_views;
create policy "owner reads own view counts"
  on public.business_profile_views
  for select
  to authenticated
  using (public.owns_business(place_id));

-- ── increment ──────────────────────────────────────────────────────────────
-- Bumps today's bucket for a place_id. Returns void so a caller learns nothing
-- about a business it doesn't own (the count is not echoed back).
--
-- Callers are expected to fire this at most once per business per session; there
-- is deliberately no server-side per-viewer dedupe, because that would require
-- storing viewer identity — the exact thing this design avoids.
create or replace function public.record_business_view(p_place_id text)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if coalesce(trim(p_place_id), '') = '' then
    return;
  end if;

  insert into public.business_profile_views (place_id, day, views)
  values (p_place_id, (now() at time zone 'utc')::date, 1)
  on conflict (place_id, day)
  do update set views = public.business_profile_views.views + 1;
end;
$fn$;

revoke all on function public.record_business_view(text) from public;
grant execute on function public.record_business_view(text) to anon, authenticated;
