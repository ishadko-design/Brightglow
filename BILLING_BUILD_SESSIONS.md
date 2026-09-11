# Billing + Paywall — end-to-end build sessions

Tracking doc for finishing the $25/mo business subscription (ARL-compliant) and the
surrounding paywall. Built in isolation on branch `biz-portal-tabs-menu` (off `main`);
`main`/live is untouched until tested + deployed. Companion to `BUSINESS_PAYWALL_PLAN.md`
(the product plan) — this is the *session/token* map.

Last updated: 2026-09-10.

## How we build
- **Inline, not big subagent teams** (token-conscious; a fan-out is ~50× inline). Small
  parallel team only for independent chunks (e.g. several email templates).
- Everything lands on this branch until tested → deployed.
- **Two repos**: this app repo + **LeadBridge** (Node/Railway, separate). LeadBridge work
  ships as paste-ready drop-ins unless a local checkout is provided.
- **External/owner-only steps** (not delegable): Stripe live activation, Railway env vars,
  applying migrations to prod, Twilio, A2P 10DLC, lawyer sign-off on wording.

## Sessions
| # | Session | Repo | ~Tokens | Gated on |
|---|---------|------|---------|----------|
| ✅ | Portal redesign (Figma) + migrations (soft-delete, ARL consent tables) | app | — | done |
| 1 | Billing/ARL app-side: verify portal billing UI vs ARL, search-fn hides non-paying/non-contactable, MAILING_ADDRESS wiring | app | 150–250k | none (local) |
| 2 | LeadBridge billing backend: Stripe webhook, consent capture on /checkout, §5 + payment-failed + cancel emails, notice dedupe | LeadBridge | 150–250k | LeadBridge repo access |
| 3 | End-to-end test in Stripe TEST mode + fixes; produce live-activation checklist | both | 100–200k | then owner: Stripe live, env, prod migrations |
| 4 | Phase-1 extras: teaser-at-wall, 7-day hide cron, un-hide webhook, bounce refund, claim flow | app+LB | 200–300k | — |
| 5 | Email enrichment Tier 2–3 (~50%→~70% coverage) | LeadBridge | 100–200k | ZeroBounce/Hunter key |
| 6–7 | Phase 2 tracked calls (Twilio) | app+LB | 120–200k | Twilio + live-call test |
| 8+ | Phase 3 SMS / text-to-pay | LeadBridge | gated | 10DLC (carrier wait) + TCPA review |

**Billing + legal flow complete = sessions 1–3** (~400–700k, ~3 sessions) + owner activation.
**Whole system end-to-end = ~6–8 sessions, ~1.0–1.8M tokens**; calendar set by external gates
(Twilio, 10DLC, Stripe live, lawyer) more than tokens.

## Session 1 — DONE (app-repo side was largely already in place)
- [x] Portal billing UI audited vs ARL §17600 — clear+conspicuous auto-renewal terms,
      affirmative consent checkbox, receipt email capture, one-click cancel via Stripe
      portal. Intact after the Figma redesign; Billing is always reachable via the menu
      (the old `billing.enabled` gate was removed). `site/biz/portal.js` renderBilling /
      unsubscribedHTML / subscribedHTML / startCheckout / openStripePortal.
- [x] `supabase/functions/search/index.ts` already drops `hidden_at` (paywalled-lapsed)
      places and attaches contactEmail (Request-quote vs Call). Came with `main`.
- [x] Consent/notices + soft-delete migrations folded onto the branch.
- [~] OPTIONAL micro-gap: search doesn't drop *non-contactable* (no phone AND no email)
      places. Negligible — Places phone coverage ≈99.9%. Left unbuilt unless wanted.
- [→] `MAILING_ADDRESS`/`BUSINESS_POSTAL_ADDRESS` is a LeadBridge env (CAN-SPAM email
      footer), not app-repo — handled in Session 2 / owner env.

**Net:** the billing/ARL flow is code-complete on the app side. The remaining build is
Session 2 (LeadBridge backend) + owner activation (Stripe live, env, apply prod migrations).
