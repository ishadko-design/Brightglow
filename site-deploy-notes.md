# Brightglow landing site

Static site for brightglow.co — landing page (`index.html`) + Terms of Service
(`terms.html`). No build step; the folder deploys as-is.

Styling mirrors the app: tokens from `design/tokens.json` (bg `#131315`,
accent `#0039F5`, 32px radii), Lato/Poppins fonts copied from
`Brightglow/Fonts/`, and the splash gradient recreated in CSS.

## Deploy (Cloudflare Pages, free)

1. https://dash.cloudflare.com → Workers & Pages → Create → Pages →
   **Upload assets** (drag this `site/` folder), project name `brightglow`.
   (Or connect the git repo with build output directory `site`.)
2. Project → Custom domains → add `brightglow.co` and `www.brightglow.co`.
3. In Namecheap (Domain List → brightglow.co → Advanced DNS), add the records
   Cloudflare shows, typically:
   - `CNAME` `@`   → `brightglow.pages.dev`
   - `CNAME` `www` → `brightglow.pages.dev`
   If Namecheap refuses a CNAME on `@`, the cleaner fix is to move DNS to
   Cloudflare (free): add the site in Cloudflare → it imports records → set the
   two Cloudflare nameservers in Namecheap (Domain → Nameservers → Custom DNS).
   Mail keeps working as long as the existing MX records for Private Email are
   imported/kept (`mx1.privateemail.com`, `mx2.privateemail.com`).

`_headers` sets long-lived caching for fonts and the `application/json`
content type for `/.well-known/apple-app-site-association` — needed later for
Universal Links once the app ships from the LLC Apple account.

## When the App Store listing is live

In `index.html`, find the comment above the CTA button: set the real
`https://apps.apple.com/...` URL, remove the `coming-soon` class, and update
the "Coming soon to iOS." note.

## Placeholders still open

- `terms.html` §22: `[registered address]` — fill with the LLC's registered
  address before real launch.
- Terms template note: have a California attorney review before relying on it.
