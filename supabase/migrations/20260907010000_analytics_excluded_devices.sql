-- Devices excluded from the analytics dashboard.
--
-- Every analytics_event now carries props->>'device_id' (the app's vendor id).
-- The analytics Edge Function drops any event whose device_id is listed here
-- from every aggregate — retroactively, so adding a row also removes that
-- device's PAST events from the numbers. This replaces the old per-device
-- opt-out flag: the device always reports; the server decides what to count.
--
-- Managed only by the analytics function (service role); no client access.

create table if not exists public.analytics_excluded_devices (
  device_id  text        primary key,
  note       text,
  created_at timestamptz not null default now()
);

alter table public.analytics_excluded_devices enable row level security;
-- No policies: only the service role (the analytics function) reads/writes this.
