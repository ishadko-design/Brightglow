# Business Claim — "any business can claim, nothing unverified goes live"

Goal: let **any** business claim (or create) a profile, while no sensitive action —
going public, receiving leads, editing an already-listed business — happens without
at least one proof or a human check. The old gate (OTP phone must match the
Google-listed number) becomes just the *first rung* of a verification ladder.

## Ownership states (the safety model)

A place's ownership is one of:

- **unclaimed** — `business_places.owner_user_id IS NULL`. Public listing shows
  Google-derived info only.
- **pending** — a claim exists but isn't proven. The claimant can build a **draft**
  profile, but it is **not public** and the place **cannot receive/route leads** to
  them. `owner_user_id` stays NULL; the claim lives in `business_claims`.
- **verified** — proof passed (or a reviewer approved). `owner_user_id = user`,
  claim `status = verified`. Full edit + public + leads.

Key rule: **an existing, already-listed business can never be taken over into a
public/lead-receiving state without a passing proof or reviewer approval.** Pending
is the universal catch-all that lets anyone *start* without opening a hijack hole.

## Verification ladder (try each; first pass wins)

| # | Method | Outcome | Where |
|---|--------|---------|-------|
| 1 | Phone OTP == `business_places.phone` (Google number) | auto **verified** | DB (`owns_business`) |
| 2 | Verify the **listed** number: Twilio calls/texts a code to `business_places.phone`, claimant reads it back | auto **verified** | LeadBridge (Twilio Verify) |
| 3 | Domain email: code sent to an address at the listing's website domain | auto **verified** | LeadBridge (SendGrid) |
| 4 | CSLB license #: match name/address against loaded CSLB rows | auto **verified** (or pending w/ evidence) | DB/LeadBridge (CSLB table already loaded) |
| 5 | Manual review: none of the above → submit; sits **pending & non-public** until a reviewer approves | → **verified** on approval | LeadBridge admin |
| 6 | Not in directory at all → **create new** business | **verified** (creator owns a brand-new listing; low hijack risk) | LeadBridge + portal |

## Data model

- `business_places` (LeadBridge-owned): `owner_user_id uuid` (exists), `phone text`
  (exists), `website text`. **Dependency: `phone`/`website` must be backfilled from
  Google Places on prod or methods 1–3 have nothing to match.**
- **New** `business_claims`: `id, place_id, user_id, method, status
  (pending|verified|rejected), evidence jsonb, created_at, reviewed_by, reviewed_at`.
  One place can have at most one non-rejected claim.
- `business_profiles`: gains a **draft/publish** notion — a pending claim's edits are
  draft-only. Simplest: profile is only public when the place is verified-owned;
  no schema change if the app/site filter public reads on `owner_user_id IS NOT NULL`.

## RLS / where secrets live

- Reads: portal may `SELECT business_places` where `norm_phone(phone)=jwt_phone()`
  (claimable by me) or `owner_user_id=auth.uid()` (mine).
- All **verification writes** (methods 2–6) run **server-side in LeadBridge with the
  service role** — they involve Twilio/SendGrid secrets and must not be client-trusted.
  LeadBridge sets `owner_user_id` / claim status after a proof passes.
- Method 1 is pure RLS (already in the `business_phone_claim` migration's
  `owns_business`).
- Apply the drifted `business_phone_claim` migration to prod first (prod is still
  email-only), then add: `business_claims` table + its RLS + `business_places`
  claimable-SELECT policy.

## Portal (`site/business/portal.js`)

- `enterDashboard()` today builds the list **only from `leads`**. Add sources:
  places I own (`owner_user_id`) and places I can claim (phone match) from
  `business_places`.
- New **"Find your business"** flow for the no-match case: search by name/city
  (Places) → pick → choose a verification method → show status.
- **Pending** screen (draft editor, "verification in progress"); **verified** →
  normal editor. **Create new** entry point when the business isn't found.

## LeadBridge endpoints (separate repo)

- `POST /api/claim/start {place_id, method}`
- `POST /api/claim/verify-listed-phone` (Twilio Verify to `business_places.phone`)
- `POST /api/claim/verify-domain-email`
- `POST /api/claim/verify-license`
- `POST /api/claim/submit-review` + an **admin review queue** (approve/reject)
- `POST /api/business/create` (method 6)
- Backfill job: Google Places `phone`/`website` → `business_places`.

## Abuse review

- Pending is never public and never receives leads.
- Notify the current verified owner when someone files a new claim on their place.
- Rate-limit claim attempts per user/number; log every attempt with evidence.
- Editing an existing verified listing from a new account requires re-verification.

## Suggested sequencing (each phase shippable)

- **Phase A (this repo, no new secrets):** `business_claims` table + states + RLS;
  apply `business_phone_claim` to prod; method **1** (phone-match) and method **6**
  (create-new) end to end; portal find/claim/pending/verified UI shell.
- **Phase B (LeadBridge):** method **2** (verify listed phone) + **3** (domain email).
- **Phase C:** method **4** (CSLB license match).
- **Phase D:** method **5** (manual review) + admin queue + owner-notification.

## Open dependency to confirm

- Is `business_places.phone` (and `website`) backfilled from Google on prod? Methods
  1–3 depend on it. Methods 5–6 do not, so Phase A can start regardless.
