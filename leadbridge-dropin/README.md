# LeadBridge drop-ins — email ETA, claim CTA, legal unsubscribe

These files belong in the **LeadBridge repo** (Node on Railway), not the app. They
add to the lead-notification email: a response-time nudge, a "Claim your page" CTA
pointing at the new web CRM (`brightglow.co/business`), a "Reply in the app" deep
link to the exact conversation, and CAN-SPAM–compliant one-click unsubscribe.

They depend on the `email_suppressions` table in this app repo's migration
`supabase/migrations/20260715000000_business_portal.sql` — **apply that migration
first**, then deploy LeadBridge.

## Files

| File | What it is |
|------|------------|
| `emailSuppressions.js` | Suppression list helpers (`isSuppressed`, `suppress`, token gen/verify) over the service-role Supabase client. |
| `unsubscribeRoute.js`  | Express router: `GET`/`POST /api/unsubscribe` (RFC 8058 one-click + human page) and `GET /api/resubscribe`. |
| `emailContent.js`      | The email HTML block (ETA + Reply-in-app + Claim CTA), the unsubscribe footer, and the `List-Unsubscribe` headers. |

## Apply steps (in the LeadBridge repo)

1. **Copy** the three `.js` files into the repo (e.g. `src/email/`). Fix the
   `require("./emailSuppressions")` relative paths if you nest them.

2. **Env vars** (Railway → Variables):
   - `UNSUBSCRIBE_SECRET` — any long random string. **Set once and never change**
     (rotating it invalidates every unsubscribe link already sent).
   - `PUBLIC_SITE_URL` = `https://brightglow.co`
   - `PUBLIC_API_URL` = the LeadBridge public URL (default already matches).
   - `BUSINESS_POSTAL_ADDRESS` — the LLC's registered postal address (CAN-SPAM
     **requires** a valid physical address in the footer). This is the same
     `[registered address]` placeholder called out in `site-deploy-notes.md`.
   - `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` — already present.

3. **Mount the route** on the Express app that serves `/api/leads`:
   ```js
   app.use(require("./src/email/unsubscribeRoute"));
   ```

4. **Guard every send** — in the mailer, before sending the lead email:
   ```js
   const { isSuppressed } = require("./src/email/emailSuppressions");
   if (await isSuppressed(contractorEmail)) return; // legally must not send
   ```

5. **Inject the content + headers** where the lead email is built:
   ```js
   const { leadEmailBlock, unsubscribeFooter, unsubscribeHeaders } = require("./src/email/emailContent");

   html = existingIntroHtml
        + leadEmailBlock({ publicId: lead.public_id, city: lead.city })
        + existingDetailsHtml
        + unsubscribeFooter(contractorEmail);

   // SendGrid: msg.headers = { ...msg.headers, ...unsubscribeHeaders(contractorEmail) };
   // Nodemailer: pass `headers: unsubscribeHeaders(contractorEmail)` on the message.
   ```

## Notes

- The **claim CTA** links to `brightglow.co/business`. A business signs in there
  with the same OTP email that already defines its identity (the inbox we matched),
  and manages its profile — name, logo, services + price ranges, and photos.
- The **"Reply in the app"** button uses the Universal Link `…/chat/<public_id>`,
  which the app opens directly to that conversation (see `ChatRouter.swift`). Until
  Universal Links are provisioned on the LLC Apple account, that link lands on the
  web page; the `brightglow://chat/<public_id>` custom scheme opens the app thread
  directly if you prefer it in the button for now.
- Suppression fails **closed**: if the check errors, the send is skipped rather
  than risk emailing an opted-out address.
- Also add `unsubscribe@brightglow.co` as a real inbox/alias (Private Email) or
  drop the `mailto:` half of the `List-Unsubscribe` header.
