# BRIGHTGLOW — CONTEXT HANDOFF (2026-07-28)

## What it is
iOS app (SwiftUI) matching customers → local service businesses (home trades + auto/moto) from Google Places. Backend = "LeadBridge" (Node/Express on Railway). Business model: customer contacts a business; **first 3 engagements free, then the business pays $25/mo** (Thumbtack/Angi-style lead-gen).

## Repos / paths / deploy
- **iOS app:** `/Users/test/Desktop/Brightglow` — Xcode `Brightglow.xcodeproj`, scheme `Brightglow`. Build check: `xcodebuild build -project Brightglow.xcodeproj -scheme Brightglow -destination 'generic/platform=iOS Simulator' -configuration Debug 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
- **LeadBridge:** `/Users/test/Desktop/Brightglow/leadbridge` — own git repo. **Deploy = `git push origin main`** → Railway auto-builds. URL `https://leadbridge-production-4065.up.railway.app`. Has a pre-push secret-guard hook.
- **Supabase** project `qxoseyrlbvblpwqzwvvk`. Edge fns: `search`, `clarify` (+ pricing, phototags…). Deploy: `supabase functions deploy <name>` (CLI logged in + linked).
- **Marketing site + business portal:** `/Users/test/Desktop/Brightglow/site` → Cloudflare Pages (has `_headers`, `_redirects`). **Deploy method UNKNOWN — ask user.** Portal at `brightglow.co/business`.

## Secrets / tokens
- `APP_TOKEN`, `PLACES_API_KEY` in `/Users/test/Desktop/Brightglow/Secrets.xcconfig` (gitignored). `PLACES_API_KEY` is iOS-bundle-restricted (won't work server-side; use the `search` fn).
- `ADMIN_TOKEN`, test-mode Stripe keys, `DATABASE_URL` (**points at PROD**) in `leadbridge/.env`. `FREE_LEAD_LIMIT=1` locally (3 default). `EMAIL_OVERRIDE_TO=hello@brightglow.co` (redirects all lead emails to test inbox → real businesses safe during testing).
- Figma token: user pastes; direct REST API works (`X-Figma-Token` header) better than the MCP connector.

## Critical gotchas
- **DB role:** LeadBridge connects as least-privilege `leadbridge_app` (RLS on, per-table `leadbridge_app_rw` policies). **ANY new table needs a GRANT + that policy or Railway 500s "permission denied".** Pattern in supabase migration `20260707000002`. `business_places` + `business_billing` already fixed via `20260727000000`.
- **Regex/resolver:** `resolveBusinessEmail.js` is ReDoS-hardened (bounded quantifiers, 1MB scan cap). Don't loosen.
- **Pre-existing failing tests:** 3 in `leadbridge/test/relayService.test.js` (threading) — NOT our work, ignore.
- Foreground `sleep` blocked in this env; use background bash for polling deploys.

## Billing state
DORMANT in prod — `billingEnabled()` gates the whole paywall; false until `STRIPE_SECRET_KEY`+`STRIPE_PRICE_ID` set in Railway. Test-mode verified end-to-end earlier (product "Brightglow for Business", $25/mo). Stripe live activation (EIN/bank) still pending. `FREE_LEAD_LIMIT`, grace `PAYWALL_GRACE_DAYS`(7), `PAYWALL_EMAIL_COOLDOWN_DAYS`(7) are env-tunable.

## THE MODEL (all built this session)
**Delivery, primary = P2P SMS:** On "Request quote", app opens the user's own Messages composer pre-filled with request text + all photos (MMS) + attribution, user taps Send. Person-to-person → **no TCPA/10DLC**. `QuoteRequestScreen.swift` `sendRequest()` → `ComposePayload` → `.sheet(item:)` → `MessageComposerView`. On send: records lead via `submitLead(notify:false)` (records + meters, no email). SMS body (current, per user's copy): `"{request}\n\nDetails:\n{first-person overview}\n\nSent via Brightglow, claim your business at brightglow.co/claim"` — **no /l/ link on normal leads** (reserved for paywall moment). Overview is now FIRST-PERSON ("I need…") via `clarify` fn prompt (deployed). Label is "Details:". `augmentedDescription` in `ClarifyTranscript.swift` builds it (falls back to Q&A pairs if no overview).

**Delivery, secondary:** Email (`buildContractorLeadEmail`) only sent when business has NO phone (`notify=true` fallback) — i.e. ~never (~99% have phones). Call = `tel:` dialer.

**Paywall (place_id-keyed, table `business_places`):** ALL channels meter equally via `meterPlaceEngagement()` in `leadbridge/src/routes/leads.js`: P2P text (notify=false path), phone tap (`POST /api/leads/engagement`, wired to both Call buttons via `LeadBridgeService.recordCall`), email lead. First 3 free → 4th+ **withheld** (email leg suppressed; P2P/call can't be stopped) + business nudged (`buildPaywallEmail`, cooldown-limited) + grace clock (`markPlaceWithheld`). Unpaid 7 days → cron `runPaywallSweep` (`jobs/cleanup.js`) hides from search (`hidden_at`) + emails CUSTOMER "not responding, try new search" (`buildBusinessNotRespondingEmail`). Pay → unhide (Stripe webhook `unhidePlacesForPlaceId`). Gate logic `evaluatePlaceGate` in `billingGate.js` (tested). Search fn excludes hidden places + attaches `contactEmail` per result.

**`/l/<id>` reply page** (`leadbridge/src/routes/landing.js`, mounted, deployed, WORKS): business taps link → sees photo+request → replies → lands in in-app chat (`saveMessage` inbound + status 'replied'). Fixed bug: `attachments` has no `created_at` (order by `id`). App mints `public_id` (`lead_<base36>`), server honors it + `notify=false`. NOTE: link is currently NOT in the normal SMS body (removed for friction) — only meant for the paywall/last-lead moment.

**Email enrichment:** `resolveBusinessEmail.js` multi-strategy scrape (mailto, Cloudflare cfemail decode, JSON-LD, `[at]`/`[dot]`, contact-page discovery, full-URL-path fetch for Google Sites). Search fn attaches `contactEmail` + background-resolves misses via `POST /internal/resolve-contacts` (admin-gated, TTL cache; timeouts 7s fetch/20s cap/conc 6; `ttlDays:0` forces re-resolve). Cached in `business_places.contact_email`. **Measured ~50–62% CA email coverage** (auto/moto same rate). NO owned email dataset (CSLB = phone only, CA contractors only). Pre-warmed 21 categories × 8 CA metros.

## App CTAs (Figma icons exported → assets)
List rows: `PhoneIcon` (Call, dark pill) + `MailIcon` (Get quote, blue pill, **only if `contactEmail` present**), matched outline weight. `ic_chat` simplified to single bubble. Gallery footer: Call / Request-quote (Request-quote only if email). All gate on `Contractor.contactEmail`.

## Compliance (from step 1)
- P2P SMS + calls user-initiated → no TCPA/10DLC. SMS is the customer's own message (their words + their clarify answers) with honest "Sent via Brightglow" attribution — legally clean; they can edit before sending.
- `MAILING_ADDRESS` = "Brightglow Technologies LLC, 332 Peoria St, Daly City, CA 94014" (config default). ToS (`site/terms.html`, `site/business-terms.html`) already name the LLC + address + CA §1789.3 notice — correct.
- Paywall nudge email = the main cold email; CAN-SPAM compliant IF `UNSUBSCRIBE_SECRET` set (see open items). Recommend a lawyer skim of the nudge copy before billing goes live.

## Paywall nudge email fixes (this session)
`buildPaywallEmail` (mailer.js): unsubscribe uses `optOutHtml` (tappable `<a>`); CTA `ctaHref: portalHref?subscribe=1`. Portal (`site/business/portal.js`) `loadBilling()` detects `?subscribe=1` → `startCheckout()` → `POST /api/billing/checkout` → Stripe (`?subscribe` survives OTP sign-in via `emailRedirectTo`). `PUBLIC_API_URL` now defaulted so unsubscribe link renders.

## OPEN ITEMS / NEXT STEPS
1. **Set `UNSUBSCRIBE_SECRET` in Railway** (suggested: `477e9ee8f0ec53e47f559dd34a28eb685900cf227ee4ae9cd6ac29fe6802e8da`) — else unsubscribe degrades to "reply unsubscribe" text (CAN-SPAM gap).
2. **Deploy the site** for `/claim` → `/business` redirect (added `site/_redirects`) — deploy method TBD.
3. **Cold-business claim/subscribe flow is the real gap:** portal signs in by OTP-to-email + only shows leads if that email matches a lead's `contractor_email`. A P2P-only business tapping "claim" may hit "no business matched." Needs design — how an email-less business we texted becomes a paying account.
4. **Communicate paywall to email-less businesses (~70%):** RECOMMENDED = make the `/l/<id>` page the universal paywall surface (banner + Subscribe button driven by place quota state; reaches ~99%, no email, legally clean since they tapped the link). Also: append paywall line to the P2P text ONLY on the last/over-quota lead (needs a `leadsRemaining`/`overQuota` flag attached to search results, like `contactEmail`). Notify "1 free lead left" on lead #3. NOT direct SMS to business (A2P/TCPA).
5. **Test safety:** `smsTestRecipient` const in `QuoteRequestScreen.swift` — set to your number to route P2P texts to yourself; MUST be `""` before shipping.
6. Rebuild the app to pick up latest copy changes (Details:/first-person/claim footer, no-link, icons, metering).
7. Later: tracked Twilio numbers (real call metering + whisper attribution), Tier-2/3 email enrichment (guess+verify, Hunter), SMS text-to-pay (needs 10DLC).
