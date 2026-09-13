-- OTA ranking config for the iOS contractor list: factor weights, small-job
-- pool widening, and licensed-trade rules. The app reads row id = 1 at launch
-- and caches it, so ranking behavior retunes from the Supabase dashboard
-- without an App Store release. Seeded once; later dashboard edits are never
-- clobbered (`on conflict do nothing`).
create table if not exists public.ranking_config (
    id integer primary key,
    config jsonb not null,
    updated_at timestamptz not null default now()
);

alter table public.ranking_config enable row level security;

drop policy if exists "ranking_config public read" on public.ranking_config;
create policy "ranking_config public read"
    on public.ranking_config for select
    using (true);

insert into public.ranking_config (id, config) values (1, '{
  "version": 1,
  "weights": {
    "reviewMatch": 0.45,
    "photoMatch": 0.30,
    "sizeFit": 0.25,
    "upstream": 0.20
  },
  "smallJob": {
    "enabled": true,
    "supplementCount": 4
  },
  "licensed": {
    "electrical": {"always": true},
    "plumbing": {"signals": ["gas"]},
    "hvac": {"signals": ["furnace", "refrigerant", "freon", "compressor", "condenser", "heat pump", "gas"]}
  }
}'::jsonb)
on conflict (id) do nothing;
