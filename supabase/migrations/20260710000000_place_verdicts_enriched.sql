-- Photo-ranking quality: mark whether a shared verdict's kept photos have been
-- enriched with rich vision tags (part / material / brand) by the `phototags`
-- function. Without this flag, cached and shared verdicts were reused with only
-- generic on-device Apple Vision labels — which have no token for "bumper",
-- "grille", a car make, etc. — so query-relevant photo ordering silently no-op'd
-- and businesses led with whatever Google returned first (often a storefront).
--
-- `false` for every existing row so each place gets enriched once on next view,
-- then the enriched verdict (labels + this flag) is re-shared for all users.
alter table public.place_verdicts
    add column if not exists enriched boolean not null default false;
