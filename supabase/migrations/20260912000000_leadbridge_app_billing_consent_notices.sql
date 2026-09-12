-- Extends the leadbridge_app least-privilege role (see
-- 20260707000002_leadbridge_least_privilege_role.sql) to the billing
-- consent/notice tables:
--   subscription_consent -- ARL renewal-consent proof (written pre-checkout)
--   billing_notices      -- §5 confirmation + dunning notice log
-- Both were created by 20260910000000 with RLS enabled and no policy for
-- leadbridge_app, so checkout failed with "permission denied for table
-- subscription_consent". Follows the 20260727 pattern exactly.

grant select, insert, update, delete on
  public.subscription_consent,
  public.billing_notices
to leadbridge_app;

-- Explicit RLS policies (no IF NOT EXISTS for policies, so drop-then-create for
-- idempotency). `for all ... using(true) with check(true)` = full access, but
-- only for this role and only on these tables.
do $$
declare t text;
begin
  foreach t in array array['subscription_consent', 'billing_notices'] loop
    execute format('drop policy if exists leadbridge_app_rw on public.%I', t);
    execute format(
      'create policy leadbridge_app_rw on public.%I for all to leadbridge_app using (true) with check (true)', t);
  end loop;
end $$;
