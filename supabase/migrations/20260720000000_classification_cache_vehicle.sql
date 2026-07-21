-- Adds the semantic vehicle verdict to the pricing classification cache.
--
-- The LLM classifier now returns { job_type, vehicle } from one call: vehicle
-- was previously decided by a hardcoded word list in pricingEngine.ts, which
-- only recognised the literal words it enumerated. "new tires for my Harley"
-- priced as a motorcycle while "my Ducati needs new tires", "tires for my
-- bike" and "new tires for my Yamaha R6" all priced as a CAR — 4 tires instead
-- of 2, roughly double. The set of ways people name a motorcycle is open-ended,
-- so it belongs on the semantic layer, not in a list.
--
-- Nullable: null means "the text said nothing about a vehicle" (every home
-- request, plus vehicle work with no auto/moto signal). Cached alongside
-- job_type so the pair costs one call per unique phrasing, as before.

alter table public.classification_cache
    add column if not exists vehicle text;

-- Which taxonomy the request belongs to ("home" / "auto"). The home taxonomy
-- owns the generic words, so without this a car's "rear left quarter window"
-- classified as a home vinyl window and quoted ~$860 of house glazing
-- (reported live 2026-07-20). Null = the text did not make it clear.
alter table public.classification_cache
    add column if not exists vertical text;
