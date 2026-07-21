-- Business-side inbox avatars.
--
-- A business viewing its received requests sees every row with the same generic
-- avatar and the same "New request" title, so requests are indistinguishable.
-- To differentiate them we draw a colored tile with the customer's initial.
--
-- The full `user_email` is deliberately NOT granted to participants (see the
-- chat migration's column-scoped grant — it's the customer's PII). So instead of
-- exposing the email, we expose ONLY its first letter via a generated column.
-- The tile color is keyed client-side to `user_id` (already granted), which is
-- unique per customer, so the letter + color together stay stable per person
-- without ever revealing the address.

alter table public.leads
  add column if not exists user_email_initial text
  generated always as (upper(left(coalesce(user_email, ''), 1))) stored;

-- Grant SELECT on just this one derived column — never the underlying email.
grant select (user_email_initial) on public.leads to authenticated;
