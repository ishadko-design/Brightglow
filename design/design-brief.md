# Brightglow — Design Brief

_Last updated: 2026-07-11_

A single reference tying the product direction we've already committed to (matching-first, chat
disambiguation, proof-of-work photo ranking, home + auto/moto verticals, pricing-secondary) to the
researched pain points it exists to solve. Use it to keep feature decisions anchored to the "why."

---

## 1. Product north star

**Brightglow's primary job is to match a person to the *right* local business for their specific
problem** — proven by that business having done a similar job — not to auction their contact
details or headline a price. Everything else (chat, photos, pricing) serves the match.

Ranking priority, in order: **did a similar job → proximity → rating (weak tiebreaker only).**

Two verticals at launch: **Home** (contractors/trades) and **Auto & moto** (Repair, Tires,
Cleaning & Detailing, Body & Paint, Glass). Home can show a price estimate; auto has no price data
source yet, so for auto the guaranteed floor is **match + proof photos**.

---

## 2. The core insight

Finding a contractor and finding a mechanic look like different problems but are the **same
problem: you cannot tell, in advance, whether this stranger is competent and honest — and every
existing tool for judging that is broken or gamed.**

- **Contractors** fail on _reliability & communication_ — ghosting after deposit, no updates,
  scope/price surprises. The buyer's fear is _"will they show up and do what they said?"_
- **Auto/moto** fails on _information asymmetry_ — overcharging, unnecessary work, jargon. The
  buyer's fear is _"am I being ripped off for something I can't evaluate?"_
- **The shared discovery layer — reviews & lead-gen marketplaces — is itself distrusted.** Reviews
  are seen as fake/inflated; lead marketplaces sell one request to 3–8 businesses and bury the user
  in calls.

Brightglow wins by **replacing gameable trust signals (star ratings, sold leads, self-description)
with hard-to-fake proof of relevant work, and by making the whole interaction legible.**

---

## 3. Pain points → design response

Each row: the researched pain point, the evidence, and the Brightglow feature that answers it.

### Shared / discovery layer

| Pain point | Evidence | Brightglow response |
|---|---|---|
| Reviews are distrusted & gamed — fake reviews, suspiciously-perfect ratings | 67% distrust reviews due to fakes; 46% distrust perfect 5★ (53% Gen Z); only 49% trust a stranger review like a personal rec | **Don't rank on rating** — it's a weak tiebreaker/floor only. Rank on demonstrated work. Ratings are near-useless as a differentiator (everyone is 4.7★+). |
| Lead marketplaces sell one request to many businesses → spam calls, overpriced/fake leads | Lead sold to 3–8 contractors; >$1,400/booked job; 10–23% fake; FTC fined HomeAdvisor $7.2M for mismatched leads | **One user → a short, ranked set of genuinely relevant businesses.** User initiates contact (chat), not an auctioned callback. This is the anti-Angi wedge. |
| Good/new/niche providers are invisible under review-count & star gates | 47% won't use <20 reviews; 31% require 4.5★+ | Surface businesses by **proof-of-work relevance**, giving quality-but-low-review-count shops a fair shot. |
| Discovery is fragmenting (Google down, AI + Apple Maps up) | Google 83%→71%; AI tools 6%→45%; Apple Maps 14%→27% | A **conversational, match-first** entry point is native to where discovery is heading, not a directory to scroll. |

### Contractors (home)

| Pain point | Evidence | Brightglow response |
|---|---|---|
| Can't distinguish reputable from fly-by-night; process is overwhelming | Top challenge in multiple homeowner surveys | **Proof-of-work photo ranking** — lead with photos of the actual job type, not a storefront. Let the work vouch for the business. |
| Poor communication / responsiveness is the #1 complaint (above price) | FIELDBOSS 2025: communication > price | **In-app chat** with the business, legible thread, response expectations built in. |
| Ghosting after deposit | Cited as most financially devastating homeowner experience | Chat creates a durable, timestamped record; keep the relationship in-app rather than a one-off lead handoff. |
| Slow, hard-to-get quotes; estimate/bid/quote confusion | Homeowners think numbers are firm; contractors mean rough | **Clarify chat scopes the job before contact** (search_terms/photo_terms/details), so the business gets a real brief and the user gets calibrated expectations. Home price estimate is a _range_, explicitly secondary. |
| Vague verbal scoping → cost overruns | House Digest / First Star | Photo + structured details captured up front and threaded into the request. |

### Auto & moto

| Pain point | Evidence | Brightglow response |
|---|---|---|
| Baseline distrust of the whole category | ~2/3 don't trust shops; 78% don't always trust their mechanic; 75M have never found a trusted shop | **Match on shops that have visibly done this exact repair** (body/paint, glass, tires) via work photos — proof over reputation. |
| Fear of overcharging & unnecessary work | 73% fear overcharge; 76% suspect unnecessary services; 74% wish they understood the work | Chat lets the user ask "is this needed / is this fair?" before committing. _(Future: auto price context — no data source yet; don't fake it.)_ |
| Opaque explanations / jargon | Mechanics diagnose well, explain poorly | Photo-derived context ("what's visibly wrong") gives the user shared vocabulary going into the conversation. |
| Younger drivers are unanchored (up for grabs) | 76% of Boomers have a trusted shop vs 55% of Millennials | The unanchored, mobile-first segment is the wedge audience — design for them. |

---

## 4. Design principles (the distilled "how")

1. **Proof over reputation.** The hero signal is _"this business has done your job,"_ shown as
   real work photos, never a star average or a self-written blurb. Ranking follows proof.
2. **One good match beats ten leads.** Never auction the user. A short, ranked, relevant set;
   the user starts the conversation. This is the explicit inverse of the lead-gen marketplaces.
3. **Legible interactions.** Every step — what the job is, who's relevant, what the business said —
   is visible and durable (chat thread, scoped brief). Reduce the information asymmetry that drives
   distrust in both verticals.
4. **Ask only what changes the match.** Clarify chat asks the minimum number of questions and stops
   the instant the match is confident (1 for a clear job, ceiling ~7 for ambiguous). No fixed cap,
   no interrogation.
5. **Honesty about what we don't know.** Where there's no reliable data (auto pricing, thin home
   categories), show a clean, intentional "coming soon" — never an LLM-guessed number or a
   review-scraped range. Trust is the whole product; don't spend it on a fake estimate.
6. **Meet discovery where it's going.** Conversational, mobile, match-first — not a scrollable
   directory competing on SEO.

---

## 5. Anti-patterns — do NOT build these

Drawn directly from what the research shows erodes trust:

- ❌ **Ranking or gating on star rating / review count** — gamed, distrusted, and buries good niche shops.
- ❌ **Selling / broadcasting a request to many businesses** — the Angi/HomeAdvisor failure mode; FTC-sanctioned.
- ❌ **Guessed or scraped prices** — LLM-invented or review-mined dollar figures. (Already on the [home-pricing-engine] do-not-resurrect list.) A wrong number is worse than no number.
- ❌ **A wall of questions before results** — respect the "ask only what changes the match" rule.
- ❌ **Storefront/exterior photos as the hero** — lead with the _work_, not the building (the enriched photo-ranking fix).

---

## 6. What success looks like

- A user reaches a **confident, relevant match in as few steps as possible**, and can see _why_
  each business was surfaced (proof photos of the matching job).
- The user **initiates one conversation with a business they chose** — not fielding cold calls.
- The experience feels **legible and honest**: clear scope, clear "here's what we know vs. don't."
- Design explicitly reads as **the opposite of a lead-gen directory**.

Candidate metrics: steps/questions to match, share of matches where the top result has a
job-matching work photo, chat initiation rate, return usage among younger (unanchored) users.

---

## 7. Open questions

- **Auto pricing:** no data source exists ([auto-moto-vertical]). Stays "coming soon" — or do we
  design a "fair-price sanity check" that's explicitly a range/context, not a quote?
- **Home pricing:** gated on EPCI licensing ([home-pricing-engine]); the whole feature is freezable.
  Design must degrade gracefully to match-only if it never ships.
- **Proof-of-work at the ranking layer:** photo relevance currently re-orders _within_ one gallery;
  cross-business re-ranking on `photo_terms` is the plan but not fully built ([matching-first-direction]).
- **Trust display:** how do we _show_ "did a similar job" as the headline trust cue without
  reintroducing a gameable score?

---

## 8. One-page positioning statement

> **For** people who need a contractor or an auto/moto shop and can't tell who to trust,
> **Brightglow** is a matching app that surfaces the few local businesses that have *demonstrably done
> your exact job* — shown as real photos of that work, not star ratings or ads.
> **Unlike** review directories (gamed, distrusted) and lead marketplaces (which sell your request to
> 3–8 businesses and bury you in cold calls), **Brightglow** matches you to the right business and lets
> *you* start one honest conversation.

**Elevator line:** _"Don't gamble on reviews or get spammed by lead-sellers — see who's actually done
your job, and message the one you pick."_

**Three proof points:**
1. **Proof over reputation** — ranked on work photos of your job type, not a 4.7★ average everyone has.
2. **One match, not an auction** — a short relevant set; you initiate contact. The anti-Angi.
3. **Legible & honest** — scoped brief up front, clear "what we know vs. don't"; no fake prices.

---

## 9. Wireframe notes — match-results screen (making "proof over reputation" visible)

The results screen is where the north star either shows or doesn't. Notes, not pixels:

- **Hero = the matching work photo, not the storefront.** Each result card leads with the business's
  photo that best matches the job (`photo_terms` / enriched ranking), full-bleed. Exterior/premises
  shots are demoted (per the enriched photo-ranking fix). If no work photo matches, the card visibly
  ranks lower — absence of proof is itself signal.
- **A "why this match" line under each result.** Plain language: _"Has photos of bumper repair like
  yours · 1.2 mi."_ Makes the ranking legible and defuses the "is this just an ad?" reflex.
- **Rating is small and secondary.** Present as a quiet floor cue (e.g. a tiny "4.7★"), never the
  headline, never the sort. Reinforces principle #1.
- **No "contact all" as the primary action.** The primary CTA per card is **Message** (start one
  conversation). Any bulk action is de-emphasized — we are explicitly not a lead broadcaster.
- **Short, ranked set — not an infinite scroll.** Show the confident matches first; make "see more"
  deliberate. A directory-length list undercuts "we matched you."
- **Price line is honest-state, not always-on.** Home: a labelled _range_ when the engine has data;
  auto: a clean "Price estimate: coming soon." Never a guessed number.
- **Auto/moto pill** (car ↔ moto) stays where it is; switching re-ranks on the same proof logic.

---

## 10. Prioritized backlog (from the open questions)

Ordered by leverage on the north star. P0 = most directly makes "proof over reputation" real.

| # | Item | Why it matters | Notes |
|---|---|---|---|
| **P0** | Cross-business re-ranking on `photo_terms` | Today photo relevance only re-orders *within* one gallery; the north star needs it *across* businesses | Reuse lazily-screened gallery photos as the "did this job" proxy; no new Places Photo calls ([matching-first-direction]) |
| **P0** | "Why this match" explainer line on result cards | Turns the ranking from a black box into a trust cue — directly answers review distrust | Client-render from the same terms used to rank |
| **P1** | "Did a similar job" headline trust cue (open Q) | The single most important display decision; must not become a gameable score | Design exploration needed — badge? photo-count? proof, not points |
| **P1** | Message-first result cards; de-emphasize bulk contact | Encodes the anti-auction positioning in the UI | Removes the "send to all" default prominence |
| **P2** | Auto "fair-price sanity check" — decide build vs. defer | Addresses the #1 auto fear (overcharging) without a real pricing source | Must be an explicit *range/context*, never a quote; or stay "coming soon" ([auto-moto-vertical]) |
| **P2** | Graceful degradation if home pricing (EPCI) never ships | Whole pricing feature is freezable; design must not break | Match-only fallback must feel intentional ([home-pricing-engine]) |
| **P3** | Response-time expectations in chat | Communication is the #1 contractor complaint | Set/expose expected reply window in the thread |

---

### Source appendix

- Auto trust: [AAA — Most U.S. Drivers Leery of Auto Repair Shops](https://newsroom.aaa.com/2016/12/u-s-drivers-leery-auto-repair-shops/) · [ConsumerAffairs Mechanic Trust Survey 2026](https://www.consumeraffairs.com/automotive/auto-mechanics-trust-issues.html) · [WomenAutoKnow](https://www.womenautoknow.com/auto-industry-statistics/)
- Contractor pain: [FIELDBOSS 2025 HVAC survey](https://www.fieldboss.com/blog/hvacs-real-problem-isnt-price-its-poor-communication/) · [Forbes — contractor ghosting](https://www.forbes.com/home-improvement/contractor/what-to-do-when-contractor-ghosts-you/) · [House Digest](https://www.housedigest.com/799621/mistakes-everyone-makes-when-hiring-contractors/) · [Legal Eagle — estimate vs bid vs quote](https://legaleaglecontractors.com/getting-estimate-quote-bid/)
- Discovery & reviews: [BrightLocal Local Consumer Review Survey 2026](https://www.brightlocal.com/research/local-consumer-review-survey/) · [BrightLocal — fake reviews](https://www.brightlocal.com/blog/lcrs-fake-reviews/) · [Roofing Contractor 2025 homeowner survey](https://www.roofingcontractor.com/articles/100649-2025-homeowner-roofing-survey-tracking-the-journey) · [ACHR News — 91% rely on reviews](https://www.achrnews.com/articles/155206-91-of-homeowners-rely-on-online-reviews-before-picking-contractors)
- Lead-gen marketplaces: [FTC v. HomeAdvisor ($7.2M)](https://www.ftc.gov/news-events/news/press-releases/2023/01/ftc-order-requires-homeadvisor-pay-72-million-stop-deceptively-marketing-its-leads-home-improvement) · [Adapt Digital — HomeAdvisor vs Angi vs Thumbtack 2026](https://adaptdigitalsolutions.com/articles/homeadvisor-vs-angieslist-vs-houzz-vs-porch-vs-thumbtack-vs-yelp-vs-bark/)
