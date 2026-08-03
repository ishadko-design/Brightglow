-- Owner DELETE for business_profiles.
--
-- The portal's "Delete profile" runs a client-side
--   sb.from("business_profiles").delete().eq("place_id", …)
-- but the original business_portal migration granted only insert/update and
-- created only insert/update policies. With RLS enabled, a delete that matches
-- no policy affects 0 rows and returns NO error, so the profile silently
-- survived and the UI re-rendered it unchanged ("cannot delete").
--
-- Gate delete on the same ownership check the update policy already uses.
grant delete on public.business_profiles to authenticated;

drop policy if exists "owner can delete own profile" on public.business_profiles;
create policy "owner can delete own profile"
  on public.business_profiles
  for delete
  to authenticated
  using (public.owns_business(place_id));
