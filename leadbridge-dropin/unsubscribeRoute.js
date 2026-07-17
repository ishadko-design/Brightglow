// Drop-in for the LeadBridge repo (Node/Express on Railway).
//
// One-click unsubscribe endpoint (CAN-SPAM + RFC 8058). Mount it on the same
// Express app that serves /api/leads. Two behaviors on the SAME url:
//   * POST  → RFC 8058 one-click (mail clients auto-POST the List-Unsubscribe-Post
//             url). Records the opt-out, returns 200, no body needed.
//   * GET   → a human clicking the link in the email. Records the opt-out and
//             shows a small confirmation page with an "undo" (resubscribe) link.
//
//   GET  /api/unsubscribe?e=<email>&t=<token>
//   POST /api/unsubscribe   (e, t in query or form body)
//   GET  /api/resubscribe?e=<email>&t=<token>   (undo)
//
// The token (see emailSuppressions.unsubscribeToken) authenticates the address so
// no login is needed and links can't be enumerated.

const express = require("express");
const { suppress, tokenValid, norm } = require("./emailSuppressions");

const router = express.Router();
router.use(express.urlencoded({ extended: false })); // for POSTed form bodies

const BRAND = "Brightglow";
const page = (title, body) => `<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title} — ${BRAND}</title>
<style>
  body{margin:0;background:#131315;color:#fff;font-family:system-ui,sans-serif;
       min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
  .card{max-width:440px;text-align:center}
  h1{font-size:22px;margin:0 0 12px}p{color:rgba(255,255,255,.6);line-height:1.5;margin:0 0 20px}
  a{color:#8aa5ff}
</style></head><body><div class="card">${body}</div></body></html>`;

function params(req) {
  const e = req.query.e || (req.body && req.body.e);
  const t = req.query.t || (req.body && req.body.t);
  return { email: norm(e), token: t };
}

// RFC 8058 one-click: mail clients POST here automatically. Keep it side-effect-
// only and cheap; no HTML needed.
router.post("/api/unsubscribe", async (req, res) => {
  const { email, token } = params(req);
  if (!email || !tokenValid(email, token)) return res.status(400).send("Invalid link.");
  try { await suppress(email, "unsubscribe"); res.status(200).send("Unsubscribed."); }
  catch (err) { console.error(err); res.status(500).send("Try again later."); }
});

// Human click.
router.get("/api/unsubscribe", async (req, res) => {
  const { email, token } = params(req);
  if (!email || !tokenValid(email, token)) {
    return res.status(400).send(page("Invalid link", "<h1>That link isn't valid.</h1><p>Contact hello@brightglow.co and we'll take you off the list.</p>"));
  }
  try {
    await suppress(email, "unsubscribe");
    const undo = `/api/resubscribe?e=${encodeURIComponent(email)}&t=${encodeURIComponent(token)}`;
    res.status(200).send(page("Unsubscribed",
      `<h1>You're unsubscribed.</h1><p>We won't email <b>${email}</b> about new job requests anymore.</p>
       <p>Changed your mind? <a href="${undo}">Resubscribe</a>.</p>`));
  } catch (err) {
    console.error(err);
    res.status(500).send(page("Error", "<h1>Something went wrong.</h1><p>Please try again in a moment.</p>"));
  }
});

// Undo — deletes the suppression row.
router.get("/api/resubscribe", async (req, res) => {
  const { email, token } = params(req);
  if (!email || !tokenValid(email, token)) return res.status(400).send("Invalid link.");
  try {
    const { createClient } = require("@supabase/supabase-js");
    const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    await supa.from("email_suppressions").delete().eq("email", email);
    res.status(200).send(page("Resubscribed", `<h1>You're back on.</h1><p>We'll email <b>${email}</b> when a customer requests your services.</p>`));
  } catch (err) { console.error(err); res.status(500).send(page("Error", "<h1>Something went wrong.</h1>")); }
});

module.exports = router;
