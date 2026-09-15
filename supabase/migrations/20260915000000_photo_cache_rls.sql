-- Security (2026-09-15): the photo_cache table shipped without RLS enabled;
-- the Supabase security advisor flagged it as rls_disabled_in_public (the anon
-- key had full read/write/delete on it). Only the `photo` Edge Function writes,
-- via the service-role key (bypasses RLS). Public read matches the original
-- migration's documented intent ("anon/authenticated may read"); this only
-- removes the anon write/delete surface.
alter table public.photo_cache enable row level security;

drop policy if exists "photo_cache public read" on public.photo_cache;
create policy "photo_cache public read"
  on public.photo_cache for select to anon, authenticated using (true);
