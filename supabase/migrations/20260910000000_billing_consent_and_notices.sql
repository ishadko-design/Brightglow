-- ARL compliance storage for the $25/mo business subscription.
--
-- California's Automatic Renewal Law (Bus. & Prof. Code §17600 et seq.) requires
-- keeping PROOF of the consumer's express consent to the auto-renewal terms for
-- 3 years (or 1 year after the contract ends, whichever is longer), and it's good
-- practice to log the acknowledgment notices we send. Both tables are written ONLY
-- by LeadBridge with the service-role key (which bypasses RLS) — same as the other
-- billing rows, which hold Stripe ids and payment state and must never be
-- client-readable. RLS is enabled with NO policies: no anon/authenticated path in
-- or out. You read these from the SQL editor / a service-role query.

-- ── consent record ───────────────────────────────────────────────────────────
-- One row per checkout where the owner ticked the consent box. Written by
-- /api/billing/checkout the moment it receives {renewalConsent:true, email},
-- BEFORE the Stripe redirect, so consent is captured even if checkout is abandoned.
-- Backfilled with the Stripe ids by the webhook once the subscription is created.
create table if not exists public.subscription_consent (
  id                     uuid        primary key default gen_random_uuid(),
  consented_at           timestamptz not null default now(),
  email                  text        not null,          -- where the §5 confirmation + notices go
  renewal_consent        boolean     not null default true,
  plan_amount_cents      integer     not null default 2500,
  source                 text        not null default 'biz_portal_checkout',
  stripe_customer_id     text,                           -- filled in by the webhook
  stripe_subscription_id text,
  user_agent             text                            -- optional, from the checkout request
);

create index if not exists subscription_consent_email_idx
  on public.subscription_consent (email, consented_at desc);
create index if not exists subscription_consent_sub_idx
  on public.subscription_consent (stripe_subscription_id);

alter table public.subscription_consent enable row level security;
-- No policies on purpose: service-role only.

-- ── billing-notice log ───────────────────────────────────────────────────────
-- One row per transactional billing email sent (Email A/B/C). Proves the §5 /
-- ARL acknowledgment went out, and dedupes retries so a webhook replay doesn't
-- double-send. notice_type: 'subscription_confirmation' | 'payment_failed' |
-- 'cancellation'.
create table if not exists public.billing_notices (
  id                     uuid        primary key default gen_random_uuid(),
  sent_at                timestamptz not null default now(),
  email                  text        not null,
  notice_type            text        not null,
  stripe_customer_id     text,
  stripe_subscription_id text,
  provider_message_id    text                            -- SendGrid/SMTP id, if available
);

create index if not exists billing_notices_sub_type_idx
  on public.billing_notices (stripe_subscription_id, notice_type, sent_at desc);

alter table public.billing_notices enable row level security;
-- No policies on purpose: service-role only.
