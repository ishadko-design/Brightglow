-- Split the combined "Licensed & insured" flag into two independent trust signals.
-- `insured` already exists (see 20260715000000_business_portal.sql); add a separate
-- `licensed` boolean so the native Settings editor can offer both as checkboxes.
--
-- Backfill: the old single checkbox meant "licensed AND insured", so any row that
-- had it on keeps both true. New rows default to false.
alter table public.business_profiles
  add column if not exists licensed boolean not null default false;

update public.business_profiles set licensed = true where insured = true;
