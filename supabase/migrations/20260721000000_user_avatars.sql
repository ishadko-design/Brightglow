-- ── avatars storage bucket ────────────────────────────────────────────────
-- Backs the consumer profile's picture (Figma 1150:3839). The business side
-- already has `business-photos`, but its write policies key on the first path
-- segment being a place_id the caller owns, so a person's avatar can't live
-- there. Same shape, different key: the first segment is the caller's auth uid.
--
-- Public read matches `business-photos` — the app loads avatars straight from
-- the CDN URL, and there's nothing private in a profile picture.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "avatars public read" on storage.objects;
create policy "avatars public read"
  on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'avatars');

drop policy if exists "user writes own avatar" on storage.objects;
create policy "user writes own avatar"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and split_part(name, '/', 1) = auth.uid()::text
  );

drop policy if exists "user updates own avatar" on storage.objects;
create policy "user updates own avatar"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and split_part(name, '/', 1) = auth.uid()::text
  )
  with check (
    bucket_id = 'avatars'
    and split_part(name, '/', 1) = auth.uid()::text
  );

drop policy if exists "user deletes own avatar" on storage.objects;
create policy "user deletes own avatar"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and split_part(name, '/', 1) = auth.uid()::text
  );
