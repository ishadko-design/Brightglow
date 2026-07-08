-- LeadBridge's tables (leadbridge/sql/schema.sql) were authored for a standalone
-- Postgres box, where nothing but the Express server can reach them. When
-- DATABASE_URL is pointed at the Brightglow Supabase project instead, they land
-- unqualified in `public` -- which PostgREST serves to anyone holding the anon
-- key. The anon key ships inside the iOS binary, so that is everyone.
--
-- Tripped Supabase's `rls_disabled_in_public` advisor. Same remedy as the cache
-- tables: LeadBridge connects as `postgres` (src/db.js, a raw pg.Pool), which
-- bypasses RLS, so enabling it with no policies locks out anon/publishable
-- clients and changes nothing for the app.
--
-- IF EXISTS because schema.sql may not have been applied to every environment.

alter table if exists public.leads              enable row level security;
alter table if exists public.messages           enable row level security;
alter table if exists public.attachments        enable row level security;
alter table if exists public.contractors        enable row level security;
alter table if exists public.rate_limit_hits    enable row level security;
alter table if exists public.contractor_optouts enable row level security;
