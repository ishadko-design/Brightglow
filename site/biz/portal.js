// Brightglow for Business — client-side CRM portal.
//
// Talks DIRECTLY to Supabase (Auth + PostgREST + Storage) with the public
// publishable key. Every write is gated server-side by RLS: a business may only
// touch rows whose place_id appears on a lead addressed to its verified email
// (see supabase/migrations/20260715000000_business_portal.sql, owns_business()).
// So there is no secret here and no custom backend in the write path.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = "https://qxoseyrlbvblpwqzwvvk.supabase.co";
// Publishable (anon) key — public by design and already shipped inside the iOS
// app (SupabaseClient.swift). It grants no authority on its own: every read and
// write is gated by RLS (owns_business), so this is safe in a static page.
const SUPABASE_KEY = "sb_publishable_FvejXHJNqb_B5kC5r5cq6g_ikqjk9Vh"; // gitleaks:allow
const PHOTO_BUCKET = "business-photos";

const sb = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

// ── element helpers ─────────────────────────────────────────
const $ = (id) => document.getElementById(id);
const show = (el, on = true) => { el.hidden = !on; };
const esc = (s) => (s ?? "").replace(/[&<>"']/g, (c) => (
  { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ── app state ───────────────────────────────────────────────
let businesses = [];      // [{ place_id, name, city, leads: [...] }]
let current = null;       // the selected business
let profile = null;       // its business_profiles row (working copy)
let signedInEmail = "";   // shown in the editor's account section
let signedInPhone = "";   // E.164 of a phone-verified session; prefills the create form
let dirty = false;
let autosaveTimer = null;
// Edits persist on their own, as they do in the app. Every keystroke would be a
// write, so a change schedules a save and resets the timer — only the pause at
// the end reaches the network.
const AUTOSAVE_MS = 1200;
const markDirty = () => {
  dirty = true;
  clearTimeout(autosaveTimer);
  autosaveTimer = setTimeout(() => { saveProfile(); }, AUTOSAVE_MS);
};

// ── boot ────────────────────────────────────────────────────
(async function boot() {
  wireStaticHandlers();
  const { data: { session } } = await sb.auth.getSession();
  if (session) await enterDashboard();
  else enterAuth();
})();

// Which channel the pending code went over — drives verifyOtp's `type` and which
// step "Start over" returns to. Phone is the primary path (it reaches the ~70% of
// businesses we have no email for); `pendingPhone` holds the E.164 for verify.
let authMethod = "sms";
let pendingPhone = "";

function enterAuth() {
  show($("bootView"), false);
  show($("menuBtn"), false);
  closeMenu();
  applyUnlockIntent();
  showPhoneStep();
  show($("authView"), true);
  $("phone").focus();
}

// Arriving from a paywall "Unlock" CTA (?subscribe=1) means this is an existing
// business coming back to pay — not a cold visitor claiming a listing. Reframe
// the sign-in cards from "Claim your business" to a login-to-unlock intent so the
// heading matches why they're here. Left untouched for the normal claim entry.
function applyUnlockIntent() {
  if (!new URLSearchParams(location.search).get("subscribe")) return;
  const title = "Unlock your leads";
  const sub = "Sign in with the email or phone your customers reach you on — "
    + "then you're one tap from subscribing.";
  ["phoneStep", "emailStep"].forEach((id) => {
    const card = document.getElementById(id);
    if (!card) return;
    const h = card.querySelector(".card-title");
    const p = card.querySelector("p.muted");
    if (h) h.textContent = title;
    if (p) p.textContent = sub;
  });
}

// The signed-out screen has three sign-in panels and only ever one is on screen.
// (The marketing intro/hero is gone — sign-in is the landing.) `only` names the
// visible one.
function showStep(only) {
  ["phoneStep", "emailStep", "codeStep"].forEach((id) =>
    show($(id), id === only)
  );
  clearAuthMsg();
}

function clearAuthMsg() {
  $("authMsg").className = "form-msg";
  $("authMsg").textContent = "";
  $("code").value = "";
}

function showPhoneStep() { authMethod = "sms"; showStep("phoneStep"); }

function showEmailStep() { authMethod = "email"; showStep("emailStep"); }

function showCodeStep(target) {
  $("codeTarget").textContent = target;
  showStep("codeStep");
  $("code").focus();
}

// US phone → E.164 for Supabase (it wants the country code). null if not a
// plausible 10-digit US number. Mirrors normalizePhone in the app/LeadBridge.
function toE164US(v) {
  const d = String(v || "").replace(/\D/g, "");
  const ten = d.length === 11 && d[0] === "1" ? d.slice(1) : d;
  return ten.length === 10 ? `+1${ten}` : null;
}

// Restart: back to whichever method was in use so a typo can be corrected and a
// fresh code requested. The previous code is abandoned (it simply expires).
$("restartBtn").addEventListener("click", () => {
  if (authMethod === "email") { showEmailStep(); $("email").focus(); }
  else { showPhoneStep(); $("phone").focus(); }
});

// Phone is the landing step; the email step's "Back" link returns to it.
document.querySelectorAll('[data-goto="phone"]').forEach((b) =>
  b.addEventListener("click", () => { showPhoneStep(); $("phone").focus(); }));

// Swap between the phone (primary) and email (alternate) sign-in methods.
$("useEmailBtn").addEventListener("click", () => { showEmailStep(); $("email").focus(); });
$("usePhoneBtn").addEventListener("click", () => { showPhoneStep(); $("phone").focus(); });

// ── auth: phone one-time code (primary) ─────────────────────
$("phoneForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const msg = $("authMsg");
  const phone = toE164US($("phone").value);
  if (!phone) {
    msg.className = "form-msg err";
    msg.textContent = "Enter a 10-digit US phone number.";
    return;
  }
  const btn = $("sendSmsBtn");
  btn.disabled = true; btn.textContent = "Sending…";
  msg.className = "form-msg"; msg.textContent = "";
  const { error } = await sb.auth.signInWithOtp({ phone });
  btn.disabled = false; btn.textContent = "Text me a code";
  if (error) {
    console.error("signInWithOtp(phone) failed:", error);
    msg.className = "form-msg err";
    msg.textContent = authErrorText(error);
  } else {
    authMethod = "sms";
    pendingPhone = phone;
    showCodeStep($("phone").value.trim());   // show what they typed
  }
});

// ── auth: email one-time link ───────────────────────────────
$("authForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = $("email").value.trim().toLowerCase();
  const msg = $("authMsg");
  if (!email) return;
  const btn = $("sendLinkBtn");
  btn.disabled = true; btn.textContent = "Sending…";
  msg.className = "form-msg"; msg.textContent = "";
  const { error } = await sb.auth.signInWithOtp({
    email,
    // Keep ?lead=… across the sign-in round-trip, so a business arriving from a
    // job email still lands on that job after authenticating.
    options: { emailRedirectTo: location.origin + location.pathname + location.search },
  });
  btn.disabled = false; btn.textContent = "Send sign-in code";
  if (error) {
    console.error("signInWithOtp failed:", error);   // full object for diagnosis
    msg.className = "form-msg err";
    msg.textContent = authErrorText(error);
  } else {
    authMethod = "email";
    showCodeStep(email);   // step 2 replaces step 1; its copy names the address
  }
});

// Code fallback: verify the 6-digit OTP the same email carries. Works when the
// magic link won't (rewritten/pre-fetched by an email client, or the template
// only sends a code). On success detectSessionInUrl is irrelevant — verifyOtp
// establishes the session directly, so we can enter the dashboard.
$("codeForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const token = $("code").value.trim();
  const msg = $("authMsg");
  if (!token) return;
  const btn = $("verifyCodeBtn");
  btn.disabled = true; btn.textContent = "Verifying…";
  // Verify against whichever channel sent the code. SMS uses the stashed E.164;
  // email reads the field back (unchanged since it was entered).
  const params = authMethod === "sms"
    ? { phone: pendingPhone, token, type: "sms" }
    : { email: $("email").value.trim().toLowerCase(), token, type: "email" };
  const { error } = await sb.auth.verifyOtp(params);
  btn.disabled = false; btn.textContent = "Verify & sign in";
  if (error) {
    console.error("verifyOtp failed:", error);
    msg.className = "form-msg err";
    msg.textContent = /expired|invalid|token/i.test(error?.message || "")
      ? "That code is wrong or expired. Request a new code and try again."
      : authErrorText(error);
  } else {
    await enterDashboard();
  }
});

// Turn a Supabase auth error into something a business owner can act on. GoTrue
// sometimes hands back an empty body, which surfaces as the literal string "{}"
// — never show that. Falls back to a plain-English message, and maps the two
// failures we actually expect (rate limit, redirect not allow-listed).
function authErrorText(error) {
  const raw = (error?.message || "").trim();
  const junk = !raw || raw === "{}" || raw === "[object Object]";
  const status = error?.status;

  if (status === 429 || /rate limit|too many/i.test(raw)) {
    return "Too many attempts. Wait a minute and try again.";
  }
  if (/redirect|not allowed|invalid.*url/i.test(raw)) {
    return "This site isn't allow-listed for sign-in yet. Contact hello@brightglow.co.";
  }
  if (junk) {
    return "Couldn't send the link right now. Check the address and try again — if it keeps failing, email hello@brightglow.co.";
  }
  return raw;
}

// ── dashboard load ──────────────────────────────────────────
// Set just before enterDashboard() when the owner should land in Settings rather
// than Requests — e.g. right after creating a brand-new business, so they go
// straight to filling in their page instead of an empty request list.
let landOnEditor = false;

async function enterDashboard() {
  show($("authView"), false);
  show($("bootView"), true);

  const { data: { session } } = await sb.auth.getSession();
  signedInEmail = (session && session.user && session.user.email) || "";
  signedInPhone = (session && session.user && session.user.phone) || "";

  // Phone-verified business: persist ownership (owner_user_id) for every place this
  // number was texted. Best-effort and not awaited-for-visibility — RLS already
  // returns their leads by phone match below; this just makes ownership durable and
  // gives billing an anchor for a business we have no email for.
  if (session && session.user && session.user.phone) {
    authedFetch("/api/claim/phone", { method: "POST" }).catch(() => {});
  }

  // Leads addressed to this business (RLS returns only mine). place_id is the
  // claim/join key; business_name/city seed the default display. Old leads with
  // a null place_id can't be claim-checked, so they're skipped for management.
  const { data: leads, error } = await sb
    .from("leads")
    .select("id, place_id, business_name, city, status, public_id, created_at, website, user_email_initial, business_last_read_at, messages(direction, body_text, created_at)")
    .is("business_hidden_at", null)   // hide requests the business dismissed
    .order("created_at", { ascending: false });

  if (error) { fail(error.message); return; }

  const byPlace = new Map();
  for (const l of leads || []) {
    if (!l.place_id) continue;
    if (!byPlace.has(l.place_id)) {
      byPlace.set(l.place_id, {
        place_id: l.place_id,
        name: l.business_name || "Your business",
        city: l.city || "",
        website: l.website || "",
        leads: [],
      });
    }
    byPlace.get(l.place_id).leads.push(l);
  }
  // Second source: places I already own, or can claim outright because my
  // OTP-verified phone matches the Google-listed number (method 1). A lead-less
  // business exists only here, so without this it could never surface.
  // See BUSINESS_CLAIM_PLAN.md.
  try {
    const { data: places } = await sb.rpc("my_claimable_places");
    for (const p of places || []) {
      let biz = byPlace.get(p.place_id);
      if (!biz) {
        biz = { place_id: p.place_id, name: p.business_name || "Your business",
                city: "", website: p.website || "", leads: [] };
        byPlace.set(p.place_id, biz);
      }
      biz.claimable = !p.owned;   // phone-matched but not yet owned -> offer a claim
    }
  } catch (err) {
    console.error("my_claimable_places failed:", err);   // non-fatal; leads still work
  }
  businesses = [...byPlace.values()];

  if (businesses.length === 0) {
    noBusiness();   // dead end -> offer to create a brand-new listing (method 6)
    return;
  }

  // Unified inbox: merge all leads into the first business so the Requests tab
  // shows everything together. The chips are hidden via CSS (.biz-switcher).
  const _all = [];
  for (const _b of businesses) for (const _l of (_b && _b.leads) || []) _all.push(_l);
  _all.sort((a, b) => ((a && a.created_at) < (b && b.created_at) ? 1 : -1));
  businesses[0].leads = _all;


  // ?lead=<public_id> — the "Claim profile" button in a job email carries the
  // lead it's about, so open THAT business on Requests rather than dumping the
  // owner on a generic page and making them hunt for the job.
  const wantLead = new URLSearchParams(location.search).get("lead");
  const target = wantLead
    ? businesses.find((b) => b.leads.some((l) => l.public_id === wantLead))
    : null;
  await selectBusiness(target || businesses[0]);
  if (target) {
    const lead = target.leads.find((l) => l.public_id === wantLead);
    if (lead) await openThread(lead);   // straight into the conversation
  }

  show($("bootView"), false);
  show($("menuBtn"), true);   // signed in — the hamburger holds sign out / billing / delete
  // Landing view: a `?lead=` deep link (from a job email) opened a thread above, so
  // stay on it; a just-created business goes to Settings to fill its page in;
  // everyone else lands on Requests (the Dashboard is gone).
  if (target) showView("chats");
  else if (landOnEditor) { landOnEditor = false; openEditor(); }
  else showView("chats");
  renderSwitcher();
  loadBilling();   // not awaited: the dashboard is usable while this resolves
}

// ── billing ─────────────────────────────────────────────────
// Subscription state is keyed on the signed-in EMAIL, not on a claimed page —
// one row per business inbox — so this is rendered once, independent of the
// business switcher.
//
// Unlike profile edits, none of this goes direct to Supabase: billing rows are
// service-role-only (they hold the Stripe customer id and payment state), so
// every call here goes through LeadBridge via the same-origin /api proxy.
let billing = null;
let billingStatus = null;   // last /api/billing/status failure, surfaced in the error

async function authedFetch(path, options = {}) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error("Your session expired — reload and sign in again.");
  return fetch(path, {
    ...options,
    headers: {
      ...(options.headers || {}),
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
  });
}

async function loadBilling() {
  try {
    const resp = await authedFetch("/api/billing/status");
    if (!resp.ok) throw new Error(`status ${resp.status}`);
    billing = await resp.json();
    billingStatus = null;
  } catch (err) {
    console.error("billing status failed:", err);
    billing = null;
    billingStatus = err && err.message ? err.message : "failed";
  }
  // Billing lives in the menu unconditionally now — if the status call failed we
  // just leave `billing` null and openBilling() retries / surfaces an error.
  if (!billing) return;
  renderBilling();

  const params = new URLSearchParams(location.search);

  // A paywall email's "Subscribe" CTA lands here with ?subscribe=1. Once the
  // owner is signed in, take them straight into Stripe Checkout instead of
  // making them find the Billing tab and click Subscribe again — that's what
  // "one tap to subscribe" from the email promises. Only when there's actually
  // something to buy; an already-subscribed business just lands on Billing.
  if (params.get("subscribe") && !billing.subscribed) {
    // Drop the trigger so a reload or back-navigation doesn't bounce them into
    // Checkout a second time.
    params.delete("subscribe");
    const qs = params.toString();
    history.replaceState({}, "", location.pathname + (qs ? "?" + qs : ""));
    showView("billing");
    startCheckout();   // renderBilling() just drew #subscribeBtn (unsubscribed)
    return;
  }

  // Coming back from Stripe (?billing=success|cancelled) — land on Billing so
  // the outcome is the first thing seen, rather than the profile editor.
  if (params.get("billing")) showView("billing");
}

function renderBilling() {
  const el = $("billingState");
  const flash = billingFlash();
  el.innerHTML = flash + (billing.subscribed ? subscribedHTML() : unsubscribedHTML());
  const sub = $("subscribeBtn");
  if (sub) {
    // ARL: Subscribe stays disabled until the owner ticks the consent box AND
    // gives a valid billing email — enrollment can't happen without express
    // affirmative consent to the auto-renewal terms, and we must not create a
    // subscription we have no address to send the required §5 confirmation to.
    // (Businesses can sign in by phone, so signedInEmail is often blank here.)
    const consent = $("renewConsent");
    const email = $("billingEmail");
    const refresh = () => { sub.disabled = !(consent.checked && validEmail(email.value)); };
    consent.addEventListener("change", refresh);
    email.addEventListener("input", refresh);
    sub.addEventListener("click", startCheckout);
    refresh();   // if the email was prefilled, only the checkbox is left to tick
  }
  const manage = $("manageBtn");
  if (manage) manage.addEventListener("click", openStripePortal);
}

// Stripe sends the browser back here after Checkout. Success is optimistic on
// purpose: the subscription is recorded by the webhook, which may land a beat
// after the redirect, so we say "activating" and re-poll rather than showing a
// stale "not subscribed" next to a completed payment.
function billingFlash() {
  const state = new URLSearchParams(location.search).get("billing");
  if (state === "success" && !billing.subscribed) {
    setTimeout(loadBilling, 2000);
    return `<p class="form-msg ok">Payment received — activating your subscription…</p>`;
  }
  if (state === "cancelled") {
    return `<p class="form-msg">Checkout cancelled. You haven't been charged.</p>`;
  }
  return "";
}

function unsubscribedHTML() {
  const { free_leads_used: used, free_lead_limit: limit, free_leads_remaining: left } = billing;
  const outOfLeads = left === 0;

  return `
    <div class="billing-title-wrap">
      <h2 class="billing-title">Subscribe for unlimited leads</h2>
    </div>
    <div class="billing-body-wrap">
    <div class="billing-avatars" aria-hidden="true">
      <span></span><span></span><span></span><span></span>
    </div>
    <p class="billing-lead">
      ${outOfLeads
        ? `You're out of free leads \u2014 new customer requests are waiting, but we can't pass them along until you subscribe.`
        : `After your ${limit} free leads (${left} left), your business will no longer be shown to potential clients. A subscription keeps customer requests coming.`}
    </p>
    <label class="field-label" for="billingEmail">Email (required)</label>
    <input type="email" id="billingEmail" autocomplete="email" inputmode="email" maxlength="200"
           placeholder="you@yourbusiness.com" value="${esc(signedInEmail)}">
    <p class="fineprint">Email for your receipt &amp; billing notices. We'll send your subscription
      confirmation and any billing notices here.</p>
    <div class="arl-box">
      <p><strong>This is an automatically renewing subscription.</strong></p>
      <ul>
        <li>You'll be charged <strong>$25.00</strong> today.</li>
        <li>It renews automatically for <strong>$25.00 every month</strong>, until you cancel.</li>
        <li><strong>Cancel anytime in one click</strong> from this Billing page \u2014 no phone call, no email.</li>
      </ul>
    </div>
    <label class="consent" for="renewConsent">
      <input type="checkbox" id="renewConsent">
      <span>I agree to the <a href="../business-terms.html">Business Terms</a> and understand this
        subscription renews automatically at $25/month until I cancel.</span>
    </label>
    <button class="primary-btn wide billing-cta" id="subscribeBtn" disabled>Subscribe</button>
    <p class="billing-caption">$25/month for unlimited leads</p>
    </div>`;
}

function subscribedHTML() {
  const renews = billing.current_period_end ? fmtDate(billing.current_period_end) : null;
  const pastDue = billing.needs_payment_update;
  // Scheduled cancellation: still active until the period ends, but the copy
  // must not say "Renews" \u2014 nothing is renewing.
  const canceling = billing.cancel_at_period_end && !pastDue;

  return `
    <div class="billing-title-wrap">
      <h2 class="billing-title">Subscription <span class="text-active-green">active</span></h2>
      ${pastDue ? `<span class="pill warn">Payment failed</span>` : ``}
    </div>
    <div class="billing-body-wrap">
    ${pastDue
      ? `<p class="form-msg err">
           We couldn't charge your card. You're still receiving leads for now \u2014 update your
           card to avoid an interruption.
         </p>`
      : ``}
    <p class="billing-lead">
      You\u2019re on the $25/month plan with unlimited leads.${renews ? (canceling ? ` Cancels ${renews} \u2014 you won\u2019t be charged again.` : ` Renews ${renews}.`) : ``}
    </p>
    <button class="btn-secondary lg wide" id="manageBtn">
      ${pastDue ? `Update card` : `Cancel subscription`}
    </button>
    <p class="billing-caption">Opens your secure Stripe billing page, where you can update your card,
      download invoices, or cancel \u2014 takes effect at the end of the period you've paid for.</p>
    </div>`;
}

// RFC-5322-lite: enough to catch typos and empty submits; the server and Stripe
// validate for real.
function validEmail(v) { return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test((v || "").trim()); }

async function startCheckout() {
  const btn = $("subscribeBtn");
  const consent = $("renewConsent");
  const email = $("billingEmail").value.trim().toLowerCase();
  if (!consent || !consent.checked || !validEmail(email)) return;   // never charge without consent + a valid email
  btn.disabled = true; btn.textContent = "Opening secure checkout…";
  try {
    // Send consent + the billing email: the server persists a dated consent record
    // (ARL requires keeping proof 3 years / 1 year post-cancel), keys Stripe Checkout
    // to this address, and sends the §5 confirmation + billing notices here.
    const resp = await authedFetch("/api/billing/checkout", {
      method: "POST",
      body: JSON.stringify({ renewalConsent: true, email }),
    });
    if (!resp.ok) {
      // TEMP-DIAG (2026-09-12): surface the server's reason for the 400.
      const data = await resp.json().catch(() => ({}));
      const detail = data && data.reason ? ': ' + data.reason : '';
      throw new Error(`Couldn't start checkout (${resp.status}${detail}).`);
    }
    const { url } = await resp.json();
    location.href = url;      // Stripe-hosted — no card data touches this page
  } catch (err) {
    console.error("checkout failed:", err);
    btn.disabled = false; btn.textContent = "Subscribe";
    alert(err.message || "Couldn't open checkout. Try again, or email hello@brightglow.co.");
  }
}

async function openStripePortal() {
  const btn = $("manageBtn");
  const label = btn.textContent;
  btn.disabled = true; btn.textContent = "Opening…";
  try {
    const resp = await authedFetch("/api/billing/portal", { method: "POST" });
    if (!resp.ok) throw new Error(`Couldn't open billing (${resp.status}).`);
    const { url } = await resp.json();
    location.href = url;
  } catch (err) {
    console.error("portal failed:", err);
    btn.disabled = false; btn.textContent = label;
    alert(err.message || "Couldn't open your billing page. Try again, or email hello@brightglow.co.");
  }
}

// Dead end: there's no Settings to reach, so the topbar Sign out is the only way
// out — the one place it still appears.
function fail(text) {
  show($("bootView"), false);
  show($("chatsView"), false);
  show($("tabs"), false);
  show($("menuBtn"), true);
  const c = $("authView");
  c.hidden = false;
  c.innerHTML = `<h1>Nothing to manage here</h1><p class="muted">${esc(text)}</p>
    <button class="ghost-btn" onclick="location.reload()" style="margin-top:16px">Reload</button>`;
}

// No lead- or phone-matched business for this account. Instead of a separate
// "create your business" gate, drop the owner straight into Settings with an
// empty draft: they fill the same fields as any business, and the FIRST save
// mints the listing (create_business, in saveProfile). The number they just
// verified prefills the phone field. See BUSINESS_CLAIM_PLAN.md.
function noBusiness() {
  current = { place_id: null, name: "", city: "", website: "", leads: [], draft: true };
  businesses = [current];
  profile = {
    place_id: null, display_name: "", about: "", website: "",
    email: signedInEmail || "",          // display-only prefill (not persisted yet)
    phone: prettyPhone(signedInPhone),
    services: [{ name: "", price_min: null, price_max: null, unit: "job" }],
    photos: [], licensed: false, insured: false, accepting_work: true,
  };
  dirty = false;
  renderProfile();
  renderServices();
  renderPhotos();
  renderLeads();
  show($("bootView"), false);
  show($("authView"), false);
  show($("menuBtn"), true);
  openEditor();       // land straight in Settings — the page IS the setup now
  renderSwitcher();
  loadBilling();      // not awaited
}

// E.164 (+1XXXXXXXXXX) → "+1 (XXX) XXX-XXXX" for the prefill, so the verified
// number reads like a phone number (with country code) rather than a raw token.
// Anything else passes through unchanged.
function prettyPhone(e164) {
  const m = String(e164 || "").match(/^\+1(\d{3})(\d{3})(\d{4})$/);
  return m ? `+1 (${m[1]}) ${m[2]}-${m[3]}` : (e164 || "");
}

// Claim-first write gate. A place is writable when it's NOT `claimable` — i.e. it
// matched a lead (owns_business passes via the lead's email/phone) or is already
// owned (business_places.owner_user_id). A phone-matched-but-unclaimed place is
// writable only AFTER claim_business() stamps ownership; calling it here means the
// owner never has to hit the claim banner before editing. Returns false if the
// claim couldn't be established, so callers can surface an error instead of a raw
// RLS rejection.
async function ensureWritable() {
  if (!current) return false;
  if (!current.claimable) return true;
  const { data: ok, error } = await sb.rpc("claim_business", { p_place_id: current.place_id });
  if (error || !ok) { console.error("claim before write failed:", error); return false; }
  current.claimable = false;
  return true;
}

// ── business switching ──────────────────────────────────────
function renderSwitcher() {
  const el = $("bizSwitcher");
  if (businesses.length < 2) { show(el, false); return; }
  el.innerHTML = businesses.map((b, i) =>
    `<button class="biz-chip ${b === current ? "is-active" : ""}" data-i="${i}">${esc(b.name)}</button>`
  ).join("");
  el.querySelectorAll(".biz-chip").forEach((chip) =>
    chip.addEventListener("click", () => selectBusiness(businesses[+chip.dataset.i])));
  show(el, true);
}

async function selectBusiness(biz) {
  if (dirty) await saveProfile();   // never lose an edit when switching business
  current = biz;
  const { data } = await sb.from("business_profiles").select("*").eq("place_id", biz.place_id).maybeSingle();
  profile = data || {
    place_id: biz.place_id, display_name: biz.name, website: biz.website,
    services: [], photos: [], licensed: false, insured: false, accepting_work: true,
  };
  // Prefill the contact fields from the verified identity when the page doesn't
  // already have one — the number/inbox the owner just signed in with is the
  // obvious default. (Email is display-only; phone rides through save.)
  if (!profile.email) profile.email = signedInEmail || "";
  if (!profile.phone) profile.phone = prettyPhone(signedInPhone);
  // Open one empty service block by default so the pricing section is
  // discoverable rather than a bare "Add" button (mirrors the app). Unnamed rows
  // don't count toward completeness and are dropped on save, so this never
  // persists an empty service.
  if (!profile.services || profile.services.length === 0) {
    profile.services = [{ name: "", price_min: null, price_max: null, unit: "job" }];
  }
  dirty = false;
  thread = null;                      // a thread from the previous business
  show($("threadCard"), false);
  show($("leadsCard"), true);
  renderProfile();
  renderServices();
  renderPhotos();
  renderLeads();
  renderSwitcher();
}

// ── profile fields ──────────────────────────────────────────
function renderProfile() {
  // "Preview as customer" opens the app to this place's consumer page once a
  // business is selected (brightglow://preview/<id>).
  renderPreviewQr();
  // Fields in Figma order: Name, Description, Email, Phone number.
  $("displayName").value = profile.display_name || "";
  $("about").value = profile.about || "";
  $("bizEmail").value = profile.email || "";
  $("bizPhone").value = profile.phone || "";
  $("licensed").checked = !!profile.licensed;
  $("insured").checked = !!profile.insured;
  $("acceptingWork").checked = profile.accepting_work !== false;
  renderLogo();
}

function renderLogo() {
  const el = $("logoPreview");
  const url = profile.logo_path ? publicUrl(profile.logo_path) : "";
  el.style.backgroundImage = url ? `url("${url}")` : "";
  el.textContent = url ? "" : "🏢";
  el.style.display = "flex";
  el.style.alignItems = "center";
  el.style.justifyContent = "center";
  el.style.fontSize = "28px";
  $("logoRemove").hidden = !url;
}

$("logoRemove").addEventListener("click", () => {
  profile.logo_path = null;
  renderLogo(); markDirty(); updateCompleteness();
});

// "Preview as customer" — open the app to this business's consumer page. The app
// reads the SAVED profile, so flush any pending edit first, then follow the deep
// link. On a phone with the app installed this opens the preview; on desktop the
// custom scheme is a no-op, so we tell the owner where to tap it.
const isMobile = () => /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
const previewLink = () => `brightglow://preview/${encodeURIComponent(current.place_id)}`;

// The CTA opens the app on a phone via the custom scheme. On desktop the app
// can't open, so the QR below (rendered by renderPreviewQr) is the path.
// NOTE: iOS Safari only honors a custom-scheme navigation inside the *synchronous*
// user-gesture window — an `await` before setting location.href makes iOS silently
// drop it. So fire the save without awaiting (opening the app doesn't unload this
// page, so the pending write still lands) and navigate immediately.
$("previewBtn").addEventListener("click", () => {
  if (!current?.place_id || !isMobile()) return;
  if (dirty) saveProfile();
  window.location.href = previewLink();
});

// The Preview CTA (next to Save) and its deep-link QR. The button only makes
// sense once the page exists, so it's hidden for a draft. The QR is desktop-only —
// scanning a QR on the same phone you'd tap the button on is pointless.
async function renderPreviewQr() {
  const hasPlace = !!current?.place_id;
  // The rule + Preview button + QR live in one section, hidden together for a
  // draft so the rule never floats over empty space.
  show($("previewSection"), hasPlace);
  if (!hasPlace) { show($("previewRow"), false); show($("previewLabel"), false); return; }
  // Mobile: the button opens the app. Desktop: plain text + QR (the button
  // can't open the app there, so it isn't shown).
  show($("previewBtn"), isMobile());
  show($("previewLabel"), !isMobile());
  show($("previewRow"), !isMobile());   // previewRow now wraps just the QR + hint
  if (isMobile()) return;
  try {
    const QRCode = (await import("https://esm.sh/qrcode@1.5.4")).default;
    $("previewQrImg").src = await QRCode.toDataURL(previewLink(), { margin: 1, width: 320 });
  } catch (err) {
    console.error("QR generation failed:", err);
  }
}

// Bind simple text fields → profile on input. Only the two the app's editor
// exposes; tagline/phone/website/service_area/license_number/years_in_business
// are no longer edited here, and their stored values ride through save untouched.
// Email maps to profile.email, which is display-only for now — business_profiles
// has no email column, so it isn't sent in the upsert (see saveProfile). The rest
// persist normally.
const FIELD_MAP = { displayName: "display_name", about: "about", bizEmail: "email", bizPhone: "phone" };
for (const [id, key] of Object.entries(FIELD_MAP)) {
  document.addEventListener("input", (e) => {
    if (e.target.id !== id) return;
    profile[key] = e.target.value;
    markDirty(); updateCompleteness();
  });
}
$("licensed").addEventListener("change", (e) => { profile.licensed = e.target.checked; markDirty(); });
$("insured").addEventListener("change", (e) => { profile.insured = e.target.checked; markDirty(); updateCompleteness(); });
$("acceptingWork").addEventListener("change", (e) => { profile.accepting_work = e.target.checked; markDirty(); });

// ── services editor ─────────────────────────────────────────
function renderServices() {
  const wrap = $("serviceRows");
  const rows = (profile.services || []);
  wrap.innerHTML = rows.map((s, i) => serviceCardHTML(s, i)).join("");
  wrap.querySelectorAll(".service-card").forEach((card) => {
    const i = +card.dataset.i;
    card.querySelector(".name-in").addEventListener("input", (e) => { setSvc(i, "name", e.target.value); refreshServiceDeletes(); });
    // Per-job pricing exposes min + max; hourly collapses to a single rate held
    // in price_min. Only the fields for the current unit are in the DOM.
    card.querySelector(".min-in")?.addEventListener("input", (e) => { setSvc(i, "price_min", numOrNull(e.target.value)); refreshServiceDeletes(); });
    card.querySelector(".max-in")?.addEventListener("input", (e) => { setSvc(i, "price_max", numOrNull(e.target.value)); refreshServiceDeletes(); });
    card.querySelector(".rate-in")?.addEventListener("input", (e) => { setSvc(i, "price_min", numOrNull(e.target.value)); refreshServiceDeletes(); });
    // "per hour" swaps the price fields: one rate when hourly, min+max otherwise.
    card.querySelector(".per-hour-in").addEventListener("change", (e) => {
      const hourly = e.target.checked;
      profile.services[i].unit = hourly ? "hour" : "job";
      if (hourly) profile.services[i].price_max = null;   // hourly is a single rate
      markDirty();
      renderServices();   // rebuild so the price field(s) switch
    });
    card.querySelector(".rm").addEventListener("click", () => {
      profile.services.splice(i, 1);
      // There's always one open service row — deleting the last leaves a fresh
      // blank rather than an empty section (same as the app).
      if (!profile.services.length) profile.services.push({ name: "", price_min: null, price_max: null, unit: "job" });
      renderServices(); markDirty(); updateCompleteness();
    });
  });
  refreshServiceDeletes();
}

// Deleting the sole empty row just recreates a blank one, so it's a no-op — hide
// its Delete until the row has content or a second row exists.
const serviceEmpty = (s) => !((s.name || "").trim()) && s.price_min == null && s.price_max == null;
function refreshServiceDeletes() {
  const rows = profile.services || [];
  const hide = rows.length === 1 && serviceEmpty(rows[0]);
  document.querySelectorAll("#serviceRows .service-card .rm").forEach((b) => { b.hidden = hide; });
}

// One card per service (Figma): name field, then price fields, then a row with a
// Delete pill and a "per hour" checkbox. Hourly shows one "Price per hour" field;
// per-job shows a min/max pair.
function serviceCardHTML(s, i) {
  const priceFields = s.unit === "hour"
    ? `<div class="price-single">
        <label class="field-label">Price per hour $</label>
        <input class="rate-in" type="number" min="0" placeholder="$" value="${s.price_min ?? ""}">
      </div>`
    : `<div class="price-pair">
        <div>
          <label class="field-label">Price min $</label>
          <input class="min-in" type="number" min="0" placeholder="$" value="${s.price_min ?? ""}">
        </div>
        <div>
          <label class="field-label">Price max $</label>
          <input class="max-in" type="number" min="0" placeholder="$" value="${s.price_max ?? ""}">
        </div>
      </div>`;
  return `<div class="service-card" data-i="${i}">
    <label class="field-label">Service</label>
    <input class="name-in" type="text" placeholder="Service name" value="${esc(s.name)}">
    ${priceFields}
    <div class="service-foot">
      <button type="button" class="btn-secondary sm rm">Delete</button>
      <label class="checkbox per-hour">
        <input class="per-hour-in" type="checkbox" ${s.unit === "hour" ? "checked" : ""}>
        <span class="tickbox" aria-hidden="true"><span class="box"><svg viewBox="0 0 11 9" width="11" height="9"><path d="M1.5 4.6l2.7 2.7L9.5 1.5" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></span></span>
        <span>per hour</span>
      </label>
    </div>
  </div>`;
}
const setSvc = (i, k, v) => { profile.services[i][k] = v; markDirty(); if (k === "name") updateCompleteness(); };
const numOrNull = (v) => (v === "" ? null : Number(v));

$("addServiceBtn").addEventListener("click", () => {
  (profile.services ||= []).push({ name: "", price_min: null, price_max: null, unit: "job" });
  renderServices(); markDirty();
});

// ── photos ──────────────────────────────────────────────────
function publicUrl(path) {
  return sb.storage.from(PHOTO_BUCKET).getPublicUrl(path).data.publicUrl;
}

function renderPhotos() {
  const strip = $("photoStrip");
  const photos = profile.photos || [];
  // Tiles then a trailing "+" add tile, mirroring the app's photo strip.
  strip.innerHTML = photos.map((p, i) => `
    <div class="photo-cell" data-i="${i}">
      <img src="${publicUrl(p)}" alt="" draggable="false">
      <button class="rm" data-i="${i}" title="Remove">✕</button>
    </div>`).join("")
    + `<label class="photo-add" for="photoInput" title="Add photos"><span>+</span></label>`;
  strip.querySelectorAll(".rm").forEach((b) => b.addEventListener("click", (e) => {
    e.stopPropagation();
    profile.photos.splice(+b.dataset.i, 1); renderPhotos(); markDirty(); updateCompleteness();
  }));
  wirePhotoDrag(strip);
}

function wirePhotoDrag(strip) {
  // Pointer-based strip interaction. The old HTML5 DnD hijacked the scroll
  // gesture on desktop (a drag always started a reorder, never a scroll) and
  // never worked on touch at all. Now:
  // - a plain drag scrolls the strip (mouse drag; touch keeps native momentum
  //   scrolling via overflow-x: auto),
  // - a long-press (450ms) on a tile arms reorder mode: the tile follows the
  //   pointer and drops into place on release — "drag to reorder", like the app.
  let press = null;    // {cell, x, y, scroll, timer, pointerId}
  let reorder = null;  // {cell, from, to}

  const tiles = () => [...strip.querySelectorAll(".photo-cell")];
  const indexAt = (clientX) => {
    const r = strip.getBoundingClientRect();
    const ts = tiles();
    if (!ts.length) return 0;
    // tile pitch measured live: second tile's left minus first tile's left
    const w = ts.length > 1 ? (ts[1].offsetLeft - ts[0].offsetLeft)
                            : ts[0].getBoundingClientRect().width + 8;
    const cx = clientX - r.left + strip.scrollLeft;       // content coords
    return Math.max(0, Math.min(ts.length - 1, Math.floor(cx / w)));
  };

  strip.addEventListener("pointerdown", (e) => {
    if (e.target.closest(".rm")) return;                  // remove button: not a drag
    if (e.pointerType === "mouse" && e.button !== 0) return;
    const cell = e.target.closest(".photo-cell");
    press = { cell, x: e.clientX, y: e.clientY, scroll: strip.scrollLeft,
              pointerId: e.pointerId, timer: 0 };
    if (cell) {
      press.timer = setTimeout(() => {
        if (!press) return;
        reorder = { cell, from: +cell.dataset.i, to: +cell.dataset.i };
        cell.classList.add("dragging");
        strip.style.touchAction = "none";   // the pointer owns the gesture now
        try { cell.setPointerCapture(press.pointerId); } catch (_) {}
      }, 450);
    }
  });

  strip.addEventListener("pointermove", (e) => {
    if (!press || e.pointerId !== press.pointerId) return;
    if (reorder) {
      const dx = e.clientX - press.x;
      reorder.cell.style.transform = `translateX(${dx}px)`;
      reorder.cell.style.zIndex = "2";
      reorder.to = indexAt(e.clientX);
      return;
    }
    const dx = e.clientX - press.x, dy = e.clientY - press.y;
    if (Math.abs(dx) > 8 && Math.abs(dx) > Math.abs(dy)) {
      clearTimeout(press.timer); press.timer = 0;   // it's a scroll, not a press
    }
    if (!press.timer) strip.scrollLeft = press.scroll - dx;
  });

  const end = () => {
    if (press) clearTimeout(press.timer);
    if (reorder) {
      const { cell, from, to } = reorder;
      cell.classList.remove("dragging");
      cell.style.transform = "";
      cell.style.zIndex = "";
      strip.style.touchAction = "";
      if (to !== from) {
        const arr = profile.photos;
        arr.splice(to, 0, arr.splice(from, 1)[0]);
        renderPhotos(); markDirty(); updateCompleteness();
      }
    }
    press = null; reorder = null;
  };
  strip.addEventListener("pointerup", end);
  strip.addEventListener("pointercancel", end);
}

let photoMsgTimer = null;
$("photoInput").addEventListener("change", async (e) => {
  const files = [...e.target.files];
  e.target.value = "";
  if (!files.length) return;
  const total = files.length;
  const strip = $("photoStrip");
  const addTile = strip.querySelector(".photo-add");
  // Optimistic placeholder tiles with spinners, so the strip visibly grows the
  // instant photos are picked — the upload no longer looks like it did nothing.
  files.forEach(() => {
    const d = document.createElement("div");
    d.className = "photo-cell is-uploading";
    d.innerHTML = '<span class="cell-spinner"></span>';
    strip.insertBefore(d, addTile);
  });
  const prog = $("photoProgress");
  const fill = prog.querySelector(".upload-bar span");
  const count = prog.querySelector(".upload-count");
  const msg = $("photoMsg");
  clearTimeout(photoMsgTimer);
  msg.className = "form-msg"; msg.textContent = "";
  fill.style.width = "0%"; count.textContent = `Uploading 0 of ${total}…`; prog.hidden = false;
  let done = 0;
  try {
    for (const file of files) {
      const path = await uploadImage(file);
      (profile.photos ||= []).push(path);
      done++;
      fill.style.width = Math.round((done / total) * 100) + "%";
      count.textContent = `Uploading ${done} of ${total}…`;
    }
    prog.hidden = true;
    renderPhotos(); markDirty(); updateCompleteness();
    msg.className = "form-msg ok";
    msg.textContent = total > 1 ? `${total} photos added ✓` : "Photo added ✓";
    photoMsgTimer = setTimeout(() => { msg.textContent = ""; msg.className = "form-msg"; }, 3000);
  } catch (err) {
    prog.hidden = true;
    renderPhotos();   // drop the placeholders; keep any that did upload
    msg.className = "form-msg err";
    msg.textContent = (err && err.message) || "Upload failed.";
  }
});

$("logoInput").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  e.target.value = "";
  if (!file) return;
  try {
    profile.logo_path = await uploadImage(file, "logo");
    renderLogo(); markDirty(); updateCompleteness();
  } catch (err) { alert(err.message || "Logo upload failed."); }
});

// Upload to "<place_id>/<uuid>.<ext>"; storage RLS confirms ownership by the
// place_id path segment. Returns the object path stored in the DB.
async function uploadImage(file, prefix = "") {
  // Claim-first: a phone-matched-but-unclaimed place isn't writable yet, so the
  // storage insert policy (owns_business on the path's place_id) would reject the
  // upload with "row violates row-level security policy". Establish ownership
  // before the first byte goes up.
  if (!(await ensureWritable())) {
    throw new Error("Claim this business before adding photos — tap “Claim this business”, then try again.");
  }
  const ext = (file.name.split(".").pop() || "jpg").toLowerCase().replace(/[^a-z0-9]/g, "") || "jpg";
  const path = `${current.place_id}/${prefix ? prefix + "-" : ""}${crypto.randomUUID()}.${ext}`;
  const { error } = await sb.storage.from(PHOTO_BUCKET).upload(path, file, {
    cacheControl: "31536000", upsert: false, contentType: file.type || "image/jpeg",
  });
  if (error) throw error;
  return path;
}

// ── leads / requests ────────────────────────────────────────
function renderLeads() {
  const list = $("leadsList");
  const leads = current.leads || [];
  show($("leadsEmpty"), leads.length === 0);
  list.innerHTML = leads.map((l, i) => {
    const msgs = sortMsgs(l.messages || []);
    const req = msgs.find((m) => m.direction === "outbound");   // the customer's request
    // Figma 1984:5579 list cell: the job title over the request's timestamp, and a
    // gold "new" badge on the avatar while any customer message is newer than the
    // last time the business opened this request. Reviewed requests lose the card
    // background, the title de-bolds (Poppins 300 per the Figma "Variant3"), and
    // the badge is gone.
    const stamp = fmtStamp((req && req.created_at) || l.created_at);
    const initial = esc((l.user_email_initial || l.city || "?").slice(0, 1));
    const unread = hasUnread(l, msgs);
    // Row wraps a red Delete behind the cell; the cell swipes left to reveal it.
    return `<div class="lead-row${unread ? "" : " read"}" data-i="${i}">
      <button type="button" class="lead-delete" data-i="${i}">Delete</button>
      <div class="lead-card">
        <div class="lead-avatarwrap">
          <div class="lead-avatar" data-lead="${l.id}">${initial}</div>
          ${unread ? `<span class="lead-dot"></span>` : ""}
        </div>
        <div class="lead-main">
          <div class="lead-title">${esc(jobTitle(l))}</div>
          <div class="lead-sub">${esc(stamp)}</div>
        </div>
      </div>
    </div>`;
  }).join("");
  list.querySelectorAll(".lead-row").forEach((row) => wireLeadRow(row, leads));
  loadLeadThumbs(leads);   // not awaited — initials show first, photos pop in
}

// A request counts as unread while any customer message is newer than the last
// time the business opened it (business_last_read_at, stamped by /read). A null
// stamp means never opened: any customer message makes it new.
function hasUnread(lead, msgs) {
  const readAt = lead.business_last_read_at ? Date.parse(lead.business_last_read_at) : 0;
  return (msgs || []).some((m) => m.direction === "outbound" && Date.parse(m.created_at) > readAt);
}

// Thumbnails: the request's photo in the list avatar. Attachment bytes are
// private, so they can't go in a plain <img src> — fetch the first attachment
// per lead through the authenticated /api/attachments/:id endpoint (the same one
// the thread view uses) and render the blob. One attachments query for all
// visible leads, then one fetch per lead that has a photo; object URLs are
// cached for the session. Best-effort: no photo just keeps the initial.
const thumbSeenLeads = new Set();   // lead ids whose attachment lookup ran
const leadThumbAtt = {};            // lead id -> first attachment id
const thumbUrls = new Map();        // attachment id -> object URL

async function loadLeadThumbs(leads) {
  try {
    const fresh = (leads || []).map((l) => l.id).filter((id) => !thumbSeenLeads.has(id));
    fresh.forEach((id) => thumbSeenLeads.add(id));
    if (fresh.length) {
      const { data } = await sb.from("attachments").select("id,lead_id").in("lead_id", fresh);
      for (const a of data || []) if (!leadThumbAtt[a.lead_id]) leadThumbAtt[a.lead_id] = a.id;
    }
    for (const leadId of Object.keys(leadThumbAtt)) {
      const attId = leadThumbAtt[leadId];
      let url = thumbUrls.get(attId);
      if (!url) {
        const resp = await authedFetch("/api/attachments/" + attId);
        if (!resp.ok) continue;
        url = URL.createObjectURL(await resp.blob());
        thumbUrls.set(attId, url);
      }
      document.querySelectorAll(`.lead-avatar[data-lead="${leadId}"]`).forEach((el) => {
        if (el.querySelector("img")) return;
        el.textContent = "";
        const img = document.createElement("img");
        img.src = url; img.alt = "";
        el.appendChild(img);
      });
    }
  } catch (err) { console.error("lead thumbnails failed:", err); }
}

// Swipe-to-delete on a request row (Figma 1140:2933): drag the cell left to reveal
// Delete; a plain tap opens the thread. Touch-driven — the business is on mobile.
const SWIPE_OPEN = -134;   // px the card slides: 118px Delete pill + 16px gap (Figma 1140:2933)

// Swipe-to-delete, rebuilt: a small rounded Delete pill (Figma 1140:2933) is
// revealed behind the sliding card; the cell itself never turns red, and the
// pill stays hidden until a swipe starts, so a tap can never flash it. A gesture
// only counts as a swipe once horizontal
// movement passes 10px AND dominates vertical movement — plain taps (even jittery
// ones) always fall through to openThread. Works with touch and mouse-drag.
function wireLeadRow(row, leads) {
  const i = +row.dataset.i;
  const card = row.querySelector(".lead-card");
  let startX = 0, startY = 0, dx = 0, tracking = false, swiping = false, suppressClick = false;

  const setX = (x) => { card.style.transform = x ? `translateX(${x}px)` : ""; };
  const onStart = (x, y) => {
    document.querySelectorAll(".lead-row.open").forEach((r) => { if (r !== row) r.classList.remove("open"); });
    startX = x; startY = y; dx = 0; tracking = true; swiping = false;
    card.style.transition = "none";
  };
  const onMove = (x, y) => {
    if (!tracking) return;
    const nx = x - startX, ny = y - startY;
    if (!swiping && Math.abs(nx) > 10 && Math.abs(nx) > Math.abs(ny) * 1.5) swiping = true;
    if (!swiping) return;
    row.classList.add("swiping");   // read rows are transparent at rest — the red
    dx = nx + (row.classList.contains("open") ? SWIPE_OPEN : 0);   // reveal only shows mid-gesture
    dx = Math.max(SWIPE_OPEN, Math.min(0, dx));
    setX(dx);
  };
  const onEnd = () => {
    if (!tracking) return;
    tracking = false; card.style.transition = "";
    if (swiping) {
      const opened = dx < SWIPE_OPEN / 2;
      row.classList.toggle("open", opened);
      if (opened || dx === 0) {
        row.classList.remove("swiping");   // .open keeps the red; at dx 0 nothing moved
      } else {
        // Snapping back: keep the red until the card finishes sliding home, so
        // the delete layer retreats with the card instead of vanishing early.
        card.addEventListener("transitionend", () => row.classList.remove("swiping"), { once: true });
      }
      suppressClick = true;   // swallow the click that follows a real swipe
      setTimeout(() => { suppressClick = false; }, 350);
    } else {
      row.classList.remove("swiping");
    }
    setX("");
  };
  card.addEventListener("touchstart", (e) => onStart(e.touches[0].clientX, e.touches[0].clientY), { passive: true });
  card.addEventListener("touchmove", (e) => onMove(e.touches[0].clientX, e.touches[0].clientY), { passive: true });
  card.addEventListener("touchend", onEnd);
  card.addEventListener("touchcancel", () => { tracking = false; card.style.transition = ""; row.classList.remove("swiping"); setX(""); });
  card.addEventListener("mousedown", (e) => { if (e.button === 0) onStart(e.clientX, e.clientY); });
  window.addEventListener("mousemove", (e) => onMove(e.clientX, e.clientY));
  window.addEventListener("mouseup", onEnd);
  card.addEventListener("click", () => {
    if (suppressClick) { suppressClick = false; return; }
    if (row.classList.contains("open")) { row.classList.remove("open"); return; }
    openThread(leads[i]);
  });
  const delBtn = row.querySelector(".lead-delete");
  const doDelete = (e) => {
    if (e) e.stopPropagation();
    if (delBtn.disabled) return;   // hide request already in flight — one tap deletes
    delBtn.disabled = true;
    deleteLead(leads[i], row).finally(() => { delBtn.disabled = false; });
  };
  delBtn.addEventListener("click", doDelete);
  // iOS Safari: click can be swallowed when touch handlers are nearby (button
  // shows :active but click never fires). Handle touchend directly.
  delBtn.addEventListener("touchend", (e) => {
    e.preventDefault();   // prevent the (possibly swallowed) click from double-firing
    doDelete(e);
  });
}

// Soft-delete: LeadBridge stamps business_hidden_at (service role, after verifying
// this business owns the lead); we drop the row locally. The customer's thread and
// the /l page are untouched.
async function deleteLead(lead, row) {
  try {
    const ctrl = new AbortController();
    const timeout = setTimeout(() => ctrl.abort(), 15000);
    let resp;
    try {
      resp = await authedFetch("/api/threads/" + lead.public_id + "/hide", { method: "POST", signal: ctrl.signal });
    } finally {
      clearTimeout(timeout);
    }
    if (!resp.ok) {
      let detail = "";
      try { detail = " " + JSON.stringify(await resp.json()); } catch (e) {}
      throw new Error(`hide failed (${resp.status})${detail}`);
    }
    const idx = (current.leads || []).indexOf(lead);
    if (idx >= 0) current.leads.splice(idx, 1);
    row.remove();
    show($("leadsEmpty"), (current.leads || []).length === 0);
  } catch (err) {
    console.error("delete request failed:", err);
    alert("Couldn't remove that request (" + err.message + "). Try again, or email hello@brightglow.co.");
  }
}

const sortMsgs = (m) => m.slice().sort((a, b) => (a.created_at < b.created_at ? -1 : 1));

// ── one conversation ────────────────────────────────────────
let thread = null;   // the lead whose thread is open

// Figma 1984:5579 titles read as short job summaries ("Replace 1200 sq ft
// hardwood floor w…"), not raw message text. Derive one from the customer's
// request: strip the channel prefix the app prepends ("Vehicle: Car "), drop a
// common lead-in, take the first sentence, cap it.
function jobTitle(lead) {
  const req = (lead.messages || []).find((m) => m.direction === "outbound");
  let t = (req && req.body_text ? req.body_text : "").trim().replace(/\s+/g, " ");
  if (!t) return lead.business_name || current?.name || "Request";
  t = t.replace(/^(vehicle|auto|car|home|house)\s*:\s*(car|vehicle|auto|home|house)?\s*/i, "");
  let prev;
  do {
    prev = t;
    t = t.replace(/^(i'm looking (for|to)|i am looking (for|to)|i'd like( to)?|i would like( to)?|i want( to)?|i need( to)?|i've got|i have( a| an| some)?|looking (for|to)|please|can you|could you|hi[,!. ]+)\s+/i, "");
  } while (t !== prev);
  t = t.replace(/^my\s+/i, "");
  t = t.split(/(?<=[.!?])\s/)[0];               // first sentence
  t = t.charAt(0).toUpperCase() + t.slice(1);
  if (t.length > 48) t = t.slice(0, 47).trimEnd() + "…";
  return t;
}

async function openThread(lead) {
  thread = lead;
  // Node header title = the job (derived), never the business name; the subhead is
  // the request's timestamp (Figma 2020:6841).
  $("threadTitle").textContent = jobTitle(lead);
  const req = (lead.messages || []).find((m) => m.direction === "outbound");
  $("threadTime").textContent = fmtStamp((req && req.created_at) || lead.created_at);
  // Figma 2020:6841 guidance line. The customer texted the business from their own
  // Messages, so the reply channel is that same SMS thread.
  $("threadSub").textContent = "Reply in the SMS thread the customer started.";
  $("threadMsg").textContent = "";
  $("threadPhotos").innerHTML = "";   // clear the previous thread's photos
  show($("leadsCard"), false);
  show($("threadCard"), true);
  renderThread(sortMsgs(lead.messages || []));
  await refreshThread();
  loadThreadPhotos(lead);   // not awaited — the text shows immediately
  // Opening marks the request read, clearing the inbox "new" dot (see hasUnread).
  // Optimistic local stamp so the dot is gone on back-nav; the server call is the
  // source of truth on next load.
  lead.business_last_read_at = new Date().toISOString();
  authedFetch("/api/threads/" + lead.public_id + "/read", { method: "POST" })
    .catch((e) => console.error("mark read failed:", e));
}

function closeThread() {
  thread = null;
  show($("threadCard"), false);
  show($("leadsCard"), true);
  renderLeads();
}
$("threadBack").addEventListener("click", closeThread);

// Messages come straight from Supabase — RLS already limits them to threads this
// business is a participant on (same policy the app relies on).
async function refreshThread() {
  const { data, error } = await sb
    .from("messages")
    .select("id, direction, body_text, created_at")
    .eq("lead_id", thread.id)
    .order("created_at", { ascending: true });
  if (error) { console.error("thread load failed:", error); return; }
  thread.messages = data || [];
  renderThread(thread.messages);
}

function renderThread(msgs) {
  const box = $("threadMsgs");
  // Only render messages that actually carry text — an empty body (e.g. a seed
  // lead, or a photo-only request) must NOT paint an empty bubble, which reads as
  // a broken screen. If there's no text, leave a placeholder that loadThreadPhotos
  // clears when a photo lands (a photo-only request then shows just the photo).
  // Direction is stored relative to the CUSTOMER: "outbound" = customer→business
  // (theirs), "inbound" = business→customer (mine). See ChatModels.swift.
  const shown = (msgs || []).filter((m) => (m.body_text || "").trim());
  if (!shown.length) {
    box.innerHTML = `<p class="thread-empty" id="threadEmpty">This request came in without a message.</p>`;
    return;
  }
  // The request bubble shows the job summary (Figma 2020:6841 shows the
  // summary-length text, not the full message); replies keep full text.
  const summary = jobTitle(thread);
  const request = shown.find((m) => m.direction !== "inbound");
  box.innerHTML = shown.map((m) => {
    const mine = m.direction === "inbound";
    const text = (m === request) ? summary : m.body_text;
    return `<div class="bubble ${mine ? "mine" : "theirs"}">${esc(text)}</div>`;
  }).join("");
  box.scrollTop = box.scrollHeight;
}

// The customer's photo(s), shown as attachments beneath the request (Figma
// 1140:3329). Attachment bytes are private, so they can't go in a plain <img src>
// — fetch each through the authenticated /api/attachments/:id endpoint (the same
// one the app uses) and render the blob. Best-effort: no photo just means no tile.
async function loadThreadPhotos(lead) {
  let atts = [];
  try {
    const { data } = await sb.from("attachments").select("id").eq("lead_id", lead.id);
    atts = data || [];
  } catch { return; }
  for (const a of atts) {
    try {
      const resp = await authedFetch("/api/attachments/" + a.id);
      if (!resp.ok) continue;
      const url = URL.createObjectURL(await resp.blob());
      if (!thread || thread.id !== lead.id) return;   // navigated away
      const empty = document.getElementById("threadEmpty");
      if (empty) empty.remove();   // a photo-only request shows just the photo
      const img = document.createElement("img");
      img.className = "thread-photo";
      img.alt = "Photo from the customer";
      img.src = url;
      $("threadPhotos").appendChild(img);
    } catch { /* skip a failed attachment */ }
  }
}

// Send through LeadBridge (NOT direct to Postgres): it verifies the Supabase JWT,
// derives direction from which party we are, and emails the customer so an
// offline counterparty still hears about it. Same endpoint the iOS app uses.
$("composer")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("composerInput");
  const body = input.value.trim();
  if (!body || !thread) return;

  const btn = $("composerSend");
  const msg = $("threadMsg");
  btn.disabled = true; msg.className = "form-msg"; msg.textContent = "Sending…";

  try {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) throw new Error("Your session expired — reload and sign in again.");
    const resp = await fetch(`/api/threads/${encodeURIComponent(thread.public_id)}/messages`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({ body }),
    });
    if (!resp.ok) throw new Error(`Couldn't send (${resp.status}). Try again.`);
    input.value = "";
    msg.textContent = "";
    await refreshThread();
  } catch (err) {
    console.error("send failed:", err);
    msg.className = "form-msg err";
    msg.textContent = err.message || "Couldn't send. Try again.";
  } finally {
    btn.disabled = false;
  }
});

function fmtTime(iso) {
  if (!iso) return "";
  try { return new Date(iso).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }); }
  catch { return ""; }
}

function fmtDate(iso) {
  if (!iso) return "";
  try { return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" }); }
  catch { return ""; }
}

// "MM.DD.YYYY · h:mm AM/PM" — the request-list and thread timestamp (Figma
// 2020:6841 / 1984:5579 show "10.08.2026 · 5:32 PM").
function fmtStamp(iso) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  const p = (n) => String(n).padStart(2, "0");
  const date = `${p(d.getMonth() + 1)}.${p(d.getDate())}.${d.getFullYear()}`;
  const time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return `${date} · ${time}`;
}

// ── completeness meter ──────────────────────────────────────
// The readiness meter + Views/Leads tiles were dropped with the Dashboard (Figma
// 1984:5663 has none). Kept as a no-op so the many edit handlers that used to
// refresh the meter don't each need to stop calling it.
function updateCompleteness() { /* no readiness UI anymore */ }

// ── save ────────────────────────────────────────────────────
// Returns "empty" (draft with nothing to create yet — a quiet no-op), true on a
// successful write, or false on failure. Autosave ignores the result; the Save
// button uses it to decide what to say.
async function saveProfile() {
  if (!current || !profile) return false;
  clearTimeout(autosaveTimer);

  // Draft (no place yet): the FIRST real save mints the listing. A name is
  // required to create; until there is one there's nothing to persist, so a
  // stray autosave is a quiet no-op rather than an error. Matching to existing
  // leads already happened at sign-in — a brand-new place starts clean.
  if (current.draft || !current.place_id) {
    const name = (profile.display_name || "").trim();
    if (!name) { dirty = false; return "empty"; }
    const { data: placeId, error: createErr } = await sb.rpc("create_business", {
      p_name: name,
      p_website: (profile.website || "").trim() || null,
      p_phone: (profile.phone || "").trim() || null,
    });
    if (createErr || !placeId) {
      console.error("create_business failed:", createErr);
      show($("saveFailed"), true);
      return false;
    }
    current.place_id = placeId;
    current.name = name;
    current.draft = false;
    profile.place_id = placeId;
    renderPreviewQr();   // there's a place to preview now
  }

  // Claim-first: the business_profiles upsert policy is owns_business(place_id),
  // so a phone-matched place must be claimed before the first save or the write
  // is rejected by RLS. No-op for lead-matched / already-owned / just-created places.
  if (!(await ensureWritable())) { show($("saveFailed"), true); return false; }
  const row = {
    place_id: current.place_id,
    display_name: profile.display_name || null,
    tagline: profile.tagline || null,
    about: profile.about || null,
    phone: profile.phone || null,
    website: profile.website || null,
    // Named rows only, reduced to the four persisted fields.
    services: (profile.services || [])
      .filter((s) => (s.name || "").trim())
      .map(({ name, price_min, price_max, unit }) => ({ name, price_min, price_max, unit })),
    service_area: profile.service_area || null,
    license_number: profile.license_number || null,
    licensed: !!profile.licensed,
    insured: !!profile.insured,
    years_in_business: profile.years_in_business ?? null,
    accepting_work: profile.accepting_work !== false,
    photos: profile.photos || [],
    logo_path: profile.logo_path || null,
  };
  const { error } = await sb.from("business_profiles").upsert(row, { onConflict: "place_id" });
  if (error) {
    console.error("save failed:", error);
    show($("saveFailed"), true);
    return false;
  }
  dirty = false;
  show($("saveFailed"), false);
  // reflect into the switcher label
  current.name = profile.display_name || current.name;
  renderSwitcher();
  return true;
}

// The explicit Save button: flush any pending autosave immediately and confirm.
// Autosave still runs on its own; this is the "peace of mind" control.
async function saveNow() {
  const btn = $("saveBtn");
  if (!btn) return;
  clearTimeout(autosaveTimer);
  btn.disabled = true;
  btn.textContent = "Saving…";
  const result = await saveProfile();
  btn.disabled = false;
  if (result === "empty") {
    // Nothing to save yet — a draft with no name. Nudge the one field that unblocks it.
    btn.textContent = "Save";
    $("displayName").focus();
    flashSaveHint("Add a business name to save your page.");
  } else if (result) {
    btn.textContent = "Saved ✓";
    setTimeout(() => { if ($("saveBtn")) $("saveBtn").textContent = "Save"; }, 1600);
  } else {
    btn.textContent = "Save";   // failure already surfaced via #saveFailed
  }
}

function flashSaveHint(text) {
  const el = $("saveHint");
  if (!el) return;
  el.textContent = text;
  el.hidden = false;
  clearTimeout(flashSaveHint._t);
  flashSaveHint._t = setTimeout(() => { el.hidden = true; }, 3200);
}

// ── views + guards ──────────────────────────────────────────
// Requests and Settings are the two peer tabs. Billing is reached from the menu
// (a full view with its own back button), so it's not a tab and hides the strip.
const TAB_VIEWS = ["chats", "editor"];

function showView(name) {
  closeMenu();
  show($("chatsView"), name === "chats");
  show($("editorView"), name === "editor");
  show($("billingView"), name === "billing");

  document.querySelectorAll(".tab").forEach((t) => {
    t.classList.toggle("is-active", t.dataset.view === name);
  });
  show($("tabs"), TAB_VIEWS.includes(name));
  window.scrollTo(0, 0);
}

function openEditor() {
  showView("editor");
}

// ── menu overlay ────────────────────────────────────────────
// The hamburger opens a full-screen sheet (Sign out / Billing / Delete account).
// It's just an [hidden] toggle; the entrance animation is CSS (menuIn).
function openMenu() { show($("menuOverlay"), true); }
function closeMenu() { const el = $("menuOverlay"); if (el) el.hidden = true; }

// Billing lives behind the menu now and is always reachable. If the status call
// hasn't landed (or failed), retry it before drawing, and surface an error rather
// than an empty card.
async function openBilling() {
  closeMenu();
  showView("billing");
  if (!billing) await loadBilling();
  if (!billing) {
    $("billingState").innerHTML =
      `<p class="form-msg err">Couldn't load billing right now${billingStatus ? ` (${billingStatus})` : ""}. Reload and try again, or email hello@brightglow.co.</p>`;
  }
}

async function signOut() {
  await sb.auth.signOut();
  location.reload();
}

// Permanent account deletion. COMPLETELY removes every business this owner
// holds (places, profiles, claims — nothing remains, not even public info),
// and deletes the login itself — then signs out for good. The browser's anon key
// CAN'T delete a Supabase auth user, so the actual removal runs in the
// `delete-account` Edge Function (service role); here we just invoke it and, on
// success, drop the local session and reload. Customer requests are preserved
// (they're keyed to the customer, not this owner).
// Promise-based destructive confirmation. The native confirm() only offers the
// generic OK/Cancel pair with no styling; this modal makes the action read as
// significant — red "Confirm Deletion", quiet Cancel. Resolves true on confirm.
function confirmDeleteAccount() {
  return new Promise((resolve) => {
    const overlay = $("deleteOverlay");
    const done = (value) => {
      overlay.hidden = true;
      document.removeEventListener("keydown", onKey);
      resolve(value);
    };
    const onKey = (e) => { if (e.key === "Escape") done(false); };
    $("deleteConfirm").onclick = () => done(true);
    $("deleteCancel").onclick = () => done(false);
    overlay.onclick = (e) => { if (e.target === overlay) done(false); };
    document.addEventListener("keydown", onKey);
    overlay.hidden = false;
    $("deleteCancel").focus();
  });
}

async function deleteAccount() {
  if (!(await confirmDeleteAccount())) return;
  const btn = $("menuDelete");
  btn.disabled = true; btn.textContent = "Deleting…";
  try {
    const { data, error } = await sb.functions.invoke("delete-account", { method: "POST" });
    if (error) throw new Error(error.message || "Delete failed. Please try again.");
    if (data && data.error) throw new Error(data.error);
  } catch (err) {
    btn.disabled = false; btn.textContent = "Delete account";
    alert(
      (err && err.message) ||
      "Delete failed. Please try again, or email hello@brightglow.co and we'll remove it."
    );
    return;
  }
  // The account row is gone. Sign out to clear the local session (this may 401 now
  // that the user no longer exists — that's fine) and hard-reload to the landing.
  dirty = false;
  try { await sb.auth.signOut(); } catch { /* user already deleted server-side */ }
  location.reload();
}

function wireStaticHandlers() {
  // The Requests / Settings tabs.
  document.querySelectorAll("[data-view]").forEach((el) => {
    el.addEventListener("click", () => {
      const target = el.dataset.view;
      if (target === "editor") openEditor(); else showView(target);
    });
  });
  // Menu overlay: open from the hamburger, then its three destinations.
  $("menuBtn").addEventListener("click", openMenu);
  $("menuClose").addEventListener("click", closeMenu);
  $("menuSignOut").addEventListener("click", signOut);
  $("menuBilling").addEventListener("click", openBilling);
  $("menuDelete").addEventListener("click", deleteAccount);
  $("billingBack").addEventListener("click", () => showView("chats"));
  $("saveBtn")?.addEventListener("click", saveNow);
  // Leaving inside the debounce window must not lose the edit. keepalive-style
  // flush: fire the save without awaiting, the same shape as the app's onDisappear.
  window.addEventListener("beforeunload", () => { if (dirty) saveProfile(); });
  $("retrySaveBtn").addEventListener("click", () => saveProfile());
}

