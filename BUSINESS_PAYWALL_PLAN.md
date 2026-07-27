# Business Paywall & Reach — Build Plan

**Goal:** businesses get 3 free customer engagements, then must subscribe ($25/mo) to keep receiving them. Reach businesses across channels we control (email + tracked calls, SMS later), hide non-paying/lapsed businesses from search, and never leave a customer in silence. **Immediate focus: maximize email coverage for California businesses, ship email + phone.**

**Status legend:** ✅ done · 🔜 next · ⏳ blocked on a calendar/external gate · ⬜ todo

Last updated: 2026-07-26.

---

## The model (confirmed decisions)

- **3 free engagements per business, pooled** across channels — a delivered lead email **or** a phone-modal call each burn one. Keyed on Google **`place_id`**.
- **First contact reaches the real business** (email now; tracked call later); they reply by email/relay thread or in the app. **The photo IS the product** — an async, photo-capable channel (email) is core, not optional.
- **At the wall (4th+):** business still gets a **locked teaser** notification; opening requires paying.
- **Ignore 7 days → hidden globally from search** + the waiting **customer** is emailed "not responding, try a new search." Paying **un-hides** via the Stripe webhook.
- **Catalog = contactable only, but contactable = phone OR email.** Don't hide phone-only businesses; decide the **CTA** by what we have:
  - Email resolved → **"Get Quote"** (async photo/message thread)
  - Phone only → **"Call"** (tracked number; still burns 1 of 3)
  - Both → both · Neither → hide
- **Resolve email at SEARCH time, cache per `place_id`** (not lazily on tap — avoids a dead-end when there's no email; not a mass pre-scrape — only businesses that appear get resolved, once).
- **Conversion split by digital presence:** digitally-present self-serve (web claim + subscribe); phone-only tail converts phone-natively (text-to-pay, phone-OTP claim, human concierge).

---

## Coverage & channel reality (measured)

- **Phone ≈ 99.9%** of CA contractors (Google Places `nationalPhoneNumber` + 244k CSLB rows agree). → tracked calls = primary reach.
- **Email: MEASURED 50%** of searchable CA businesses (live 90-business sample across 5 trades/cities), = **62% of those with a website** (81% have one). Up to **~65–75%** with the full enrichment stack (Tier 2–3). **No owned email dataset** (CSLB has none). Big franchises use contact forms (≈0 email) — small local operators are the winnable segment.
- **CSLB** = CA + contractors only; its value is the "Licensed" badge, not contact (phone redundant with Places).

**Channels usable today (no gate):** email · tracked calls · claim link. **Gated:** SMS (see below).

---

## Legal / compliance cheat-sheet

- **Email (CAN-SPAM):** cold B2B email is legal with a checklist — accurate headers, one-click unsubscribe (✅ built), honor opt-outs, and a **physical mailing address in every email** (⬜ `MAILING_ADDRESS` still unset → use LLC address). **No consent needed, no private lawsuits, no carrier gate.** Only real risk = domain reputation (manage with SPF/DKIM/DMARC + low bounce, already handled).
- **SMS (TCPA + 10DLC):** TCPA is a **law** (needs consent / lawful basis, honor STOP, $500–1500/text, individuals can sue). 10DLC is a **carrier registration** (days–weeks). Cold-texting businesses is the risk. Rule if we ever do it: **only text on a real customer lead, put NO photo/PII in the text (send a claim-gated link), honor STOP, lawyer-review the wording.**
- **Tracked calls:** customer-initiated → far lighter TCPA exposure, **no 10DLC**. Safe to build now.

---

## ✅ Done (this + prior sessions)

- ✅ Stripe billing built & **test-mode verified end-to-end** (checkout → webhook → gate flip → cancel → block → fail-open). `business_billing` migration applied to prod.
- ✅ `business_places` table (place_id-keyed) + 2 indexes + RLS — `leadbridge/sql/schema.sql`. Validated vs prod DB via BEGIN/ROLLBACK.
- ✅ 9 repo functions — `leadbridge/src/repo.js` (getPlace, ensurePlace, inc/decPlaceFreeLeads, markPlaceWithheld, markPlaceClaimEmailed, listPlacesToHide, hidePlace, unhidePlacesForEmail, listHiddenPlaceIds).
- ✅ `evaluatePlaceGate` — `leadbridge/src/lib/billingGate.js` + `test/placeGate.test.js` (7 tests).
- ✅ **Email enrichment — Tier 1 (deeper scraper)** — `leadbridge/src/lib/resolveBusinessEmail.js`: multi-strategy (mailto, `data-email`, **Cloudflare `data-cfemail` decode**, **JSON-LD/schema.org**, entity-decode `&#64;`, **`[at]`/`[dot]` de-obfuscation**, contact-page discovery), 2 MB read cap for footers, **fetches the full URL path** (recovers Google Sites/Wix/Linktree microsites — the low-digital segment). Hardened against **ReDoS** (bounded quantifiers + 1 MB scan cap — a malformed site could have pinned a CPU). `test/resolveBusinessEmail.test.js` **15 tests** pass. **Measured on a live 90-business CA sample (via search fn + `APP_TOKEN` from Secrets.xcconfig): 50% email / 62% of sites-with-website / 99% phone / 100% contactable.**
- ✅ Phase 0 CSLB coverage check (numbers above).

---

## Phase 1 — Self-serve paywall loop (email/web) 🔜
*No legal/carrier gates. Fully local-testable. Builds the spine both channels share. Est. ~200–300k tokens.*

- ✅ Apply `business_places` migration to prod (`business_places` + `contact_checked_at` live in prod).
- ✅ **Resolve-at-search + cache + CTA split (code done; needs deploy):**
  - LeadBridge `POST /internal/resolve-contacts` (admin-token gated) resolves+caches emails per place_id with a TTL — tested end-to-end (auth, resolve, cache hit).
  - `search` Edge fn attaches `contactEmail` from `business_places` per-request + background-resolves misses via LeadBridge. **Needs deploy + 2 secrets: `LEADBRIDGE_URL`, `LEADBRIDGE_ADMIN_TOKEN`.**
  - iOS: `Contractor.contactEmail`; **list + gallery gate the CTA** — "Request/Get quote" only when email present, else "Call". Builds clean.
  - ⬜ **Deploy both**: `supabase functions deploy search` (+ secrets) and push LeadBridge to main. Until then `contactEmail` is null → app shows Call-only.
- ⬜ **Email enrichment Tier 2–3** (raise ~30% → ~65–75%): pattern-guess (`info@/contact@/office@`) + **verification API** (ZeroBounce/NeverBounce) before use; **on-demand Hunter.io / Data Axle** for leads only. (Needs an API key + a Places/APP_TOKEN key to MEASURE the real % — see below.)
- ⬜ **Resolve-at-search-time + cache per place_id**; wire the phone-OR-email **CTA split** into the app catalog.
- ⬜ **Relay re-key** — `leadbridge/src/routes/leads.js`: `evaluatePlaceGate` + `ensurePlace`; full lead vs **teaser** by gate; count on place; `markPlaceWithheld`; one-time claim email.
- ⬜ **Email templates** — `mailer.js`: over-quota **teaser**, one-time **claim**, customer **"not responding."**
- ⬜ **Cron** — `jobs/cleanup.js`: `listPlacesToHide(7)` → `hidePlace` + email waiting customer(s).
- ⬜ **Webhook un-hide** — `stripeWebhook.js`: active sub → `unhidePlacesForEmail`.
- ⬜ **Bounce refund** — `sendgridEvents.js`: hard bounce → `decrementPlaceFreeLeads`.
- ⬜ **Search filter** — `supabase/functions/search/index.ts`: drop hidden + non-contactable place_ids.
- ⬜ **Claim flow:** phone-OTP claim + pre-built profile from Places.
- ⬜ **App:** replace hardcoded `contractorEmail: "hello@brightglow.co"` (`QuoteRequestScreen.swift:487`) with resolved email; `FREE_LEAD_LIMIT=3`.
- ⬜ **`MAILING_ADDRESS`** = LLC address (CAN-SPAM).
- ⬜ **Verify** loop end-to-end locally.

---

## Phase 2 — Tracked calls (workhorse channel) ⬜
*No legal gate (customer-initiated). Needs Twilio + live-call testing. Covers the ~70% email can't reach. ~120–200k tokens.*

- ⬜ Twilio number pool.
- ⬜ Voice webhook: whisper ("New customer from Brightglow") → bridge → log-as-engagement.
- ⬜ Pool assignment per customer↔business pair, released after a window.
- ⬜ App: dial the tracking number on "Call" (`ContractorGalleryScreen.swift:637`).
- ⬜ Paywall-on-call after 3.
- ⬜ Live-call testing.

---

## Phase 3 — Convert the phone-only tail ⏳
- ⏳ **A2P 10DLC registration** — start EARLY (carrier wait).
- ⏳ **TCPA legal review** of whisper + SMS scripts.
- ⬜ **SMS** lead alert + **text-to-pay** (Stripe payment link). Never put the photo in the text — send a claim-gated link.
- ⬜ **Concierge** onboarding for high-value tail.

---

## Cross-cutting / go-live ⬜
- ⬜ **Stripe live activation** (have LLC/EIN/bank): Dashboard activation → live product/price + live webhook to Railway URL.
- ⬜ **Railway env (on-switch):** live `STRIPE_SECRET_KEY`/`STRIPE_PRICE_ID`/`STRIPE_WEBHOOK_SECRET`, `MAILING_ADDRESS`, `BUSINESS_PORTAL_URL`.
- ⬜ **Clean up** test rows in prod (`business_billing` stray `checkout-demo-…@example.com`).

---

## Blockers right now
- **Measuring the real email %** needs a real CA business-website sample → the **`GOOGLE_PLACES_KEY`** or the search fn's **`APP_TOKEN`** (fn returned 401). Interim: sample from the `leads.website` column (our own traffic).
- **Tier 2–3 enrichment** needs a verification/enrichment **API key** (ZeroBounce / Hunter).

---

## Token estimate
| Phase | Tokens | Difficulty |
|---|---|---|
| Phase 1 (self-serve loop + enrichment) | ~200–300k | Moderate, low-risk (local-testable) |
| Phase 2 (tracked calls) | ~120–200k | Hard (live testing) |
| Phase 3 (SMS/tail) | gated | Moderate code, calendar-gated |
| **Total remaining** | **~300–500k** | multi-session |

---

## Open decisions
- ⬜ Other verticals / non-CA: no CSLB — Places phone + scraped email only. Confirm scope.
- ⬜ Billing shape for tail: $25/mo vs **pay-per-lead** for low-digital solos?
- ✅ Hide scope: **global until paid**. · ✅ Free limit **3**, grace **7 days**.

## Suggested order
**Phase 0 ✅ → Phase 1 (building now, email-first) → Stripe live → Phase 2 → Phase 3** (start 10DLC paperwork during Phase 1).
