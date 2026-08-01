# Brightglow Technologies LLC — Setup & Legal-Protection To-Do

CA single-member LLC, formed July 2026, Daly City.
Goal: finish formation and keep the liability shield ("veil") intact so the
business is a separate legal entity from Igor personally.

_Not legal advice — general procedure. One session with a CA small-business
attorney is worth it for contract/liability specifics._

---

## Done
- [x] **EIN** — IRS federal tax ID
- [x] **Business bank account** — dedicated account open

## To do now

- [ ] **Sign an Operating Agreement** — Free
  - Internal doc: proves the LLC governs itself separately from you → core veil protection.
  - Single-member template is short. Fill in owner (Ihor Shadko, 100%), sign, date,
    keep with LLC records. Different from the site Terms of Service.

- [ ] **Pay $800 franchise tax** — FTB — **$800**
  - ftb.ca.gov → Web Pay (or mail Form 3522).
  - Due ~**Oct 15, 2026** (15th day of 4th month after formation). Can pay early.
  - No first-year waiver — that expired after 2023.

- [ ] **File Statement of Information (LLC-12)** — CA Secretary of State — **$20**
  - bizfileonline.sos.ca.gov.
  - Due within **90 days of formation** (~late Oct 2026). Missing it → suspension → shield voided.

- [ ] **Daly City business license** — Daly City Finance Dept. — ~**$50–150**
  - dalycity.org → Business License. Register operating location.
  - Check home-occupation zoning if working from home.

- [ ] **Get business liability insurance**
  - LLC caps *your personal* exposure; insurance covers the *business's* exposure. Want both.

## Habits that keep the shield intact
- [ ] Sign contracts as: **"Brightglow Technologies LLC, by Ihor Shadko, Member"** — never just your name.
- [ ] **Never commingle** — no personal spending from the business account; pay yourself by transfer, then spend personally.
- [ ] **Capitalize it** — keep real operating money in the account; a $0 shell is easy to pierce.

## Recurring (so it never lapses)
- [ ] **Every year:** $800 franchise tax + Form 568 (LLC tax return)
- [ ] **Every 2 years:** LLC-12 Statement of Information
- [ ] **Every year:** Daly City business license renewal

---

## Why this gates the product
The $25/mo business paywall (App Store + Stripe) turns on only after the LLC is
live and compliant. Sequence: **LLC compliant → App Store → Stripe → flip env vars.**
See billing-launch-sequence notes.
