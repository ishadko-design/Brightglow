-- Carry the matched business's identity on the lead so the in-app chat can show
-- its logo as the conversation avatar ("business photo when available").
--
--   * place_id — keys the business's cached logo in business_enrichment (resolved
--     once at browse time by the `logos` Edge Function). This is the join key.
--   * website — lets an as-yet-uncached business resolve a logo on first chat open.
--
-- Both are public Google Places fields (safe to expose to the participant client)
-- and nullable — older leads and signed-out submits omit them, and the avatar then
-- falls back to the generic business icon.

alter table if exists public.leads
  add column if not exists place_id text,
  add column if not exists website  text;

-- Additive column grant (RLS still chooses the rows — see the participant policy
-- in 20260709000000_chat.sql; this only widens which columns a participant reads).
grant select (place_id, website) on public.leads to authenticated;
