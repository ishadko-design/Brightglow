-- Extends the leadbridge_app least-privilege role (see
-- 20260707000002_leadbridge_least_privilege_role.sql, whose closing note says
-- "future tables added to these grants should be added here too") to the two
-- tables created after it via LeadBridge's own sql/schema.sql:
--   business_billing  -- Stripe subscription state
--   business_places   -- place_id-keyed paywall state + resolved contact emails
--
-- Both have RLS enabled with no policy, and leadbridge_app is not a bypass role.
-- Without the grant + policy below, the relay (billing) and the
-- /internal/resolve-contacts endpoint fail on Railway: SELECT sees zero rows and
-- INSERT is silently denied — which is exactly what left "Get quote" showing on
-- no business (contact emails never persisted). Verified: with these applied,
-- the resolve endpoint writes and reads back its own cache.

grant select, insert, update, delete on
  public.business_billing,
  public.business_places
to leadbridge_app;

-- No IF NOT EXISTS for policies, so drop-then-create for idempotency.
do $$
declare t text;
begin
  foreach t in array array['business_billing', 'business_places'] loop
    execute format('drop policy if exists leadbridge_app_rw on public.%I', t);
    execute format(
      'create policy leadbridge_app_rw on public.%I for all to leadbridge_app using (true) with check (true)', t);
  end loop;
end $$;
