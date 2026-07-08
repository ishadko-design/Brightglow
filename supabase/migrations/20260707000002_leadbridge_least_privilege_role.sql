-- Least-privilege database role for the LeadBridge backend.
--
-- LeadBridge currently connects with the Supabase `postgres` role (its
-- DATABASE_URL, src/db.js). That role bypasses RLS and can read/write every
-- schema -- including `auth` (every user's identity) -- and alter the database.
-- If the Railway env var leaks, that's total compromise, not just LeadBridge's
-- six tables.
--
-- This creates a dedicated role scoped to exactly what LeadBridge needs and
-- nothing else. It is NOT a bypass role, so with RLS enabled on the six tables
-- it needs explicit policies to see rows; the policies below grant it full
-- access to just those tables. `anon` still has no policy and stays locked out.
-- `postgres` still bypasses RLS, so nothing changes until you cut over.
--
-- DORMANT until you do two out-of-band steps (kept out of git on purpose):
--   1. Set a password (SQL editor, not committed):
--        alter role leadbridge_app with password '<strong-random>';
--   2. Point Railway's DATABASE_URL at this role instead of postgres, same host
--      and db, e.g. postgresql://leadbridge_app:<pw>@<host>:5432/postgres?sslmode=require
--   Then smoke-test a lead submission. Rollback is instant: revert DATABASE_URL
--   to the postgres connection string.
--
-- A role with LOGIN but no password cannot authenticate on Supabase, so simply
-- applying this migration is inert.

do $$
begin
  create role leadbridge_app with login noinherit nosuperuser nocreatedb nocreaterole;
exception when duplicate_object then null;
end $$;

grant usage on schema public to leadbridge_app;

grant select, insert, update, delete on
  public.leads,
  public.messages,
  public.attachments,
  public.contractors,
  public.rate_limit_hits,
  public.contractor_optouts
to leadbridge_app;

-- Explicit RLS policies (no IF NOT EXISTS for policies, so drop-then-create for
-- idempotency). `for all ... using(true) with check(true)` = full access, but
-- only for this role and only on these tables.
do $$
declare t text;
begin
  foreach t in array array[
    'leads','messages','attachments','contractors','rate_limit_hits','contractor_optouts'
  ] loop
    execute format('drop policy if exists leadbridge_app_rw on public.%I', t);
    execute format(
      'create policy leadbridge_app_rw on public.%I for all to leadbridge_app using (true) with check (true)', t);
  end loop;
end $$;

-- Future tables added to these grants should be added here too; the role should
-- never be handed blanket schema-wide privileges.
