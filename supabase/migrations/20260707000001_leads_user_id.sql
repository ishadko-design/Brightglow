-- Add a real owner column to `leads`.
--
-- Today a lead is keyed only by `user_email` (leadbridge/sql/schema.sql), a
-- self-asserted string: /api/leads accepts whatever email the caller sends, so
-- it can't be trusted as the identity of the authenticated user. That's fine
-- while all reads go through the trusted backend, but it blocks the next step
-- of hardening -- per-user RLS policies keyed to `auth.uid()` -- which need a
-- cryptographic owner, not an email.
--
-- This adds that column as groundwork. It is intentionally NULLABLE and left
-- unpopulated: existing rows are test data with no auth user, and nothing wires
-- it yet. Populating it is a follow-up in three places -- the iOS client sends
-- the signed-in user's id, /api/leads (leadbridge/src/routes/leads.js) stores
-- it, then a policy like:
--     create policy "own leads" on public.leads
--       for select using (auth.uid() = user_id);
-- can replace backend-mediated reads. Until then this column changes nothing.
--
-- on delete set null: if an auth user is deleted, keep the lead record (it has
-- its own TTL/retention) but drop the ownership link, rather than cascade-
-- deleting relay history.

alter table if exists public.leads
  add column if not exists user_id uuid references auth.users (id) on delete set null;

create index if not exists idx_leads_user_id on public.leads (user_id);
