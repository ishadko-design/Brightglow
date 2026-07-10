-- In-app chat: let the two parties on a lead read and follow their own
-- conversation directly from Supabase (PostgREST + Realtime), gated by RLS.
--
-- Identity model (the "proper way"): a business is NOT a special account type.
-- It's an authenticated user whose verified email matches a lead's
-- contractor_email — possession of the inbox we matched (proven by Supabase
-- email OTP) IS the verification. So two roles fall out of the data:
--   * customer: leads.user_id = auth.uid()
--   * business: lower(leads.contractor_email) = lower(jwt email)
-- Same messages table, same auth, same Realtime — no bespoke business auth.
--
-- Writes still go through the LeadBridge backend (service role), which also
-- fires the email relay so an offline counterparty is still notified. So this
-- migration grants SELECT only — there is deliberately no INSERT policy.

-- Persist the business name on the lead so the customer's thread list can show
-- who they contacted. Until now it was only passed to the notification email
-- (mailer), never stored. Nullable; leads.js starts populating it going forward.
alter table if exists public.leads
  add column if not exists business_name text;

-- SECURITY DEFINER membership check. Runs as the owner so it can read `leads`
-- regardless of the caller's own row-level access, which keeps the message /
-- attachment policies from depending on (and recursing through) the leads
-- policy. Returns true iff the current JWT belongs to either party on the lead.
create or replace function public.is_lead_participant(p_lead_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
    from public.leads l
    where l.id = p_lead_id
      and (
        l.user_id = auth.uid()
        or lower(l.contractor_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
      )
  );
$fn$;

revoke all on function public.is_lead_participant(uuid) from public;
grant execute on function public.is_lead_participant(uuid) to authenticated;

-- ── leads ────────────────────────────────────────────────────────────────
-- Column-scoped grant: even though the policy lets a participant's row
-- through, they can only ever SELECT these safe columns — never user_email,
-- contractor_email, or contractor_hash (the claim secret). RLS chooses the
-- rows; the grant chooses the columns. Both are needed together.
grant select (id, public_id, business_name, city, status, created_at, user_id)
  on public.leads to authenticated;

drop policy if exists "leads owner can select" on public.leads;   -- superseded (customer-only)
drop policy if exists "chat participant can select lead" on public.leads;
create policy "chat participant can select lead"
  on public.leads
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or lower(contractor_email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

-- ── messages ─────────────────────────────────────────────────────────────
-- Every column here is safe to expose to a participant (no PII beyond the
-- body they authored / received), so a table-wide grant is fine.
grant select on public.messages to authenticated;

drop policy if exists "chat participant can select messages" on public.messages;
create policy "chat participant can select messages"
  on public.messages
  for select
  to authenticated
  using (public.is_lead_participant(lead_id));

-- ── attachments ──────────────────────────────────────────────────────────
-- The file itself is streamed by the backend (participant-authed); clients
-- only need the metadata to render/request it.
grant select (id, lead_id, mime_type, expires_at)
  on public.attachments to authenticated;

drop policy if exists "chat participant can select attachments" on public.attachments;
create policy "chat participant can select attachments"
  on public.attachments
  for select
  to authenticated
  using (public.is_lead_participant(lead_id));

-- ── Realtime ─────────────────────────────────────────────────────────────
-- Add messages to the Realtime publication so a live INSERT (a reply from the
-- other party) pushes to any subscribed client. Realtime re-checks the SELECT
-- policy above per subscriber, so a user only ever receives their own threads.
do $do$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end
$do$;
