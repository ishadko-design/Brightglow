-- Apple Ads install attribution (AdServices token exchange).
--
-- One row per device, first-write-wins: the app reports its AdServices
-- attribution token once per install and the `attribution` Edge Function
-- exchanges it with Apple (api-adservices.apple.com) to resolve the
-- campaign / ad group / keyword that drove the install.
--
-- The raw token is single-use and short-lived (24h): it is nulled out as
-- soon as Apple answers, and only its sha256 fingerprint is kept for
-- idempotency. Rows Apple hasn't answered yet stay 'pending' with the token
-- intact so the admin retry path can flush them inside the token window.
--
-- Managed only by the attribution function (service role); no client access.
-- Joined downstream with leads.sender_device_id for cost-per-sender math.

create table if not exists public.ad_attributions (
  device_id         text        primary key,
  token_sha256      text        not null,
  token             text,
  status            text        not null default 'pending'
                    check (status in ('pending', 'attributed', 'organic', 'failed')),
  org_id            bigint,
  campaign_id       bigint,
  ad_group_id       bigint,
  keyword_id        bigint,
  keyword           text,
  ad_id             bigint,
  country_or_region text,
  conversion_type   text,
  click_at          timestamptz,
  attempts          integer     not null default 0,
  last_error        text,
  created_at        timestamptz not null default now(),
  resolved_at       timestamptz
);

alter table public.ad_attributions enable row level security;
-- No policies: only the service role (the attribution function) reads/writes this.
