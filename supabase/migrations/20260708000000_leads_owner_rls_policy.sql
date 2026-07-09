-- Defense-in-depth: codify per-user ownership on `leads`.
--
-- Today nothing reads `leads` directly from a client — the iOS app only talks
-- to the LeadBridge backend (which connects as `leadbridge_app`, with its own
-- `using(true)` policy) and to Edge Functions (service role). The anon key
-- can't read `leads` at all (RLS on, no anon policy). So this policy changes
-- NOTHING operationally right now.
--
-- What it does is make the table "secure by default" for the future: if a
-- "my requests" screen is ever added that reads leads directly via PostgREST,
-- the ownership rule is already enforced at the DB layer — an authenticated
-- user can only ever see rows where they are the owner, never anyone else's.
--
-- Deliberately NO grant to `authenticated` here: without a SELECT grant the
-- policy is inert (RLS needs both grant AND policy), so no lead data — including
-- internal columns like contractor_hash — is exposed to clients yet. When the
-- read path is built, add a column-scoped view + `grant select` on just that
-- view, rather than opening the base table.
--
-- Does not affect `leadbridge_app` (separate role, separate policy) or `anon`
-- (still no policy → still locked out). Idempotent.

drop policy if exists "leads owner can select" on public.leads;
create policy "leads owner can select"
  on public.leads
  for select
  to authenticated
  using (auth.uid() = user_id);
