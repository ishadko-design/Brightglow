# Cheap Places API — backend plan

Roadmap to move Google Places work off the device and behind a backend, so the
cost is paid **once per place/area** and shared by all users instead of repeated
on every visit on every device.

## Goal & guardrails

- **Target:** per-visit cost ~$0.85 → **~$0.10–0.18**, and decouple cost from user growth.
- **Cost states for reference:** original ~$1.50 → after client-side changes ~$0.85
  (shipped) → after this backend ~$0.10–0.18.
- **Non-negotiables, baked in from the start:**
  - Google key never ships in the app binary.
  - Places caching terms respected: place IDs storable indefinitely; other place
    fields + photo names ≤ 30 days; do **not** store raw photo bytes long-term.
  - A kill-switch (feature flag) so the app can fall back to direct Google calls
    if the backend is down.

## Status legend

- [ ] not started  ·  [~] in progress  ·  [x] done

**Progress (2026-06-30):** Phases 0–3 done and deployed to project
`qxoseyrlbvblpwqzwvvk`.
- `search` Edge Function proxies Google with a server-held key and caches
  responses in `search_cache` (one search per area/category/day). Verified
  `x-cache: miss → hit`.
- Phase 3 uses a **shared verdict cache** (chosen over full server-side ML): the
  app keeps on-device Apple Vision screening but uploads each place's verdict to
  the `verdicts` Edge Function / `place_verdicts` table, so the first user to view
  a place screens it and everyone else reuses the result. Verified put → get.
- Remaining: Phase 4 hardening (auth on the functions — currently public/bounded
  by the Google quota cap; photo proxy to remove the last key from the binary).

---

## Phase 0 — Setup (½ day) — prerequisite

No Supabase project exists yet, so this phase creates it.

- [ ] **Create a Supabase project** (free tier is fine). Region close to users.
- [ ] Save Google key as a Supabase secret `GOOGLE_PLACES_KEY`.
- [ ] Create a **second, server-only** Google key (IP-restricted / unrestricted for
      server use). Keep the existing bundle-restricted key for the app's direct
      photo fetches during transition.
- [ ] **Set a daily quota cap + budget alert** in Google Cloud Console (user-only;
      do this before any testing so spend can't run away).
- [ ] Add `PlacesBackend` base URL to the app via `Secrets.xcconfig` (same pattern
      as the existing key — see secrets handling).
- **Deliverable:** an empty deployed Edge Function returning 200.
- **Acceptance:** the app can reach the function.

## Phase 1 — Proxy the search (½–1 day)

Move only Text Search behind the backend; photos still fetched directly from
Google by the app (unchanged for now).

- [ ] **Backend** `GET /search?category=&lat=&lng=&page=` → calls Google
      `places:searchText` with the current field mask; returns the shape the app
      already decodes.
- [ ] **App** `PlacesService.search()` calls the backend instead of
      `places.googleapis.com`. Keep the direct-Google path behind a feature flag
      (the kill-switch).
- **Cost impact:** none yet — security + plumbing step.
- **Acceptance:** list/gallery work identically; the API key is gone from search
  traffic; flipping the flag falls back cleanly.

## Phase 2 — Cache searches (½ day)

- [ ] **DB tables:**
  - `searches(cache_key pk, place_ids[], next_token, created_at)`
  - `places(place_id pk, name, rating, review_count, phone, address, lat, lng, reviews jsonb, refreshed_at)`
- [ ] **Backend:** `cache_key = "category|geohash5|yyyymmdd"`; on hit serve from
      Postgres, on miss call Google + upsert `places` + store result. Refresh place
      rows older than 30 days.
- **Cost impact:** Text Search drops from per-visit to ~once per area/category/day.
- **Acceptance:** repeated searches in the same area today produce **zero** new
  Text Search calls on the dashboard.

## Phase 3 — Screen photos once (2–4 days) — the big win

Where the photo savings live, and the hardest part: reproducing the on-device
Apple Vision screening server-side.

- [ ] **DB:** `place_photos(place_id, photo_name, position, is_work, screened_at, pk(place_id,photo_name))`.
- [ ] **Queue + worker:** when `/search` sees a place with no screened photos,
      enqueue it; a background function downloads the pool **once**, classifies,
      writes verdicts.
- [ ] **Screening port (phased within the phase):**
  1. Heuristics MVP: `sharp` (resolution + Laplacian blur) + `tesseract.js`
     (text-heavy gate). Ships fast.
  2. Add a model for people/vehicle/scene gates (`blazeface` + MobileNet via
     tfjs-node, or ONNX) to match current quality.
  - Fallback if quality parity matters: run the existing Swift `PhotoFilter` on a
    small macOS worker (Vision is macOS-only).
- [ ] **App:** `/search` returns each contractor's screened photo names; **delete
      the on-device `PhotoFilter` path** and the `prefetchUpcoming` / `screenBatch`
      screening logic. List/gallery just render the pre-screened set. The on-device
      `ImageCache` disk layer + `ScreeningStore` stay as a client cache on top.
- **Cost impact:** screening downloads happen once per place ever, not per visit
  per device.
- **Acceptance:** a never-before-seen area screens once (one-time burst), then
  subsequent visits by anyone show only the handful of displayed-photo fetches;
  on-device screening CPU drops to zero.

## Phase 4 — Optional hardening (later)

- [ ] Route photo display through `GET /photo/:name` proxy so the app holds **no**
      Google key at all.
- [ ] Per-place review refresh; rate-limiting / auth on endpoints (ties into the
      auth plan).
- [ ] Observability: log cache hit-rate + per-SKU call counts.

## Cross-cutting (throughout)

- **Monitoring:** small log/dashboard of cache hit-rate and Text Search / Place
  Photo counts, to see each phase's effect.
- **Rollback:** the Phase 1 feature flag stays for the whole project.

## Recommended sequence

Phase 0 → 1 → 2 deliver the security win + search savings in ~2 days, low risk.
Then pause, watch the dashboard, and tackle Phase 3 (photo savings) as a focused
effort.

## Already shipped (client-side, precursor to this)

- List strip lazy-loads (LazyHStack, 4 photos/business until scroll); gallery
  reuses the list's screened set; in-session search cache.
- On-device disk image cache + persistent screening verdicts (`ScreeningStore`),
  so repeat visits **on the same device** don't re-bill. Cross-user reuse is what
  this backend plan adds.
