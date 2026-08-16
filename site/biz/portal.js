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
  show($("dashView"), false);
  show($("signOutBtn"), false);
  showIntroStep();
  show($("authView"), true);
}

// The signed-out screen has four panels — the marketing intro, then the three
// sign-in steps — and only ever one is on screen. `only` names the visible one.
function showStep(only) {
  ["introStep", "phoneStep", "emailStep", "codeStep"].forEach((id) =>
    show($(id), id === only)
  );
  clearAuthMsg();
}

function clearAuthMsg() {
  $("authMsg").className = "form-msg";
  $("authMsg").textContent = "";
  $("code").value = "";
}

// The intro is the landing hero: its one CTA leads into the phone step. Nothing to
// submit here, so it stays clean.
function showIntroStep() { showStep("introStep"); }

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

// The intro's CTA opens the phone step; the steps' "Back" links return to it.
$("startClaimBtn").addEventListener("click", () => { showPhoneStep(); $("phone").focus(); });
document.querySelectorAll('[data-goto="intro"]').forEach((b) =>
  b.addEventListener("click", showIntroStep));

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

$("signOutBtn").addEventListener("click", signOut);

// ── dashboard load ──────────────────────────────────────────
// Set just before enterDashboard() when the owner should land in Settings rather
// than the dashboard — e.g. right after creating a brand-new business, so they go
// straight to filling in their page instead of an empty dashboard.
let landOnEditor = false;

async function enterDashboard() {
  show($("authView"), false);
  show($("bootView"), true);

  const { data: { session } } = await sb.auth.getSession();
  signedInEmail = (session && session.user && session.user.email) || "";

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
    .select("id, place_id, business_name, city, status, public_id, created_at, website, messages(direction, body_text, created_at)")
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
  show($("signOutBtn"), true);   // signed in — the topbar is the only way out
  // Landing view: a `?lead=` deep link (from a job email) opened a thread above, so
  // stay on it; a just-created business goes to Settings to fill its page in;
  // everyone else lands on the Dashboard. Messages/conversations are handled in the
  // app now, so Chats is no longer a tab — it's reachable only via a lead deep link.
  if (target) showView("chats");
  else if (landOnEditor) { landOnEditor = false; openEditor(); }
  else showView("dash");
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
  } catch (err) {
    console.error("billing status failed:", err);
    billing = null;
  }
  // The tab stays hidden unless the server says billing is switched on, so a
  // deploy without Stripe env vars simply has no billing UI rather than a
  // broken one.
  if (!billing || !billing.enabled) { show($("billingBtn"), false); return; }
  show($("billingBtn"), true);
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
    // ARL: the Subscribe button stays disabled until the owner ticks the
    // consent box, so enrollment can't happen without express affirmative
    // consent to the auto-renewal terms.
    const consent = $("renewConsent");
    consent.addEventListener("change", () => { sub.disabled = !consent.checked; });
    sub.addEventListener("click", startCheckout);
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
  const pct = limit ? Math.min(100, Math.round((used / limit) * 100)) : 0;
  const outOfLeads = left === 0;

  return `
    <h2 class="billing-head">${outOfLeads ? "You're out of free leads" : "Free leads"}</h2>
    <div class="meter"><span style="width:${pct}%" class="${outOfLeads ? "is-full" : ""}"></span></div>
    <p class="muted">${used} of ${limit} free leads used${left > 0 ? ` · ${left} left` : ""}</p>
    <p class="billing-body">
      ${outOfLeads
        ? `New customer requests matched to your business are waiting, but we can't pass them
           along until you subscribe.`
        : `After your ${limit} free leads, a subscription keeps customer requests coming.`}
    </p>
    <div class="price-row"><span class="price">$25</span><span class="muted">/month · unlimited leads</span></div>
    <div class="renewal-terms">
      <p><strong>This is an automatically renewing subscription.</strong></p>
      <ul>
        <li>You'll be charged <strong>$25.00</strong> today.</li>
        <li>It renews automatically for <strong>$25.00 every month</strong>, on this same date, until you cancel.</li>
        <li><strong>Cancel anytime in one click</strong> from this Billing page — no phone call, no email.</li>
      </ul>
    </div>
    <label class="consent" for="renewConsent">
      <input type="checkbox" id="renewConsent">
      <span>I agree to the <a href="../business-terms.html">Business Terms</a> and understand this
        subscription renews automatically at $25/month until I cancel.</span>
    </label>
    <button class="primary-btn wide" id="subscribeBtn" disabled>Subscribe</button>`;
}

function subscribedHTML() {
  const renews = billing.current_period_end ? fmtDate(billing.current_period_end) : null;
  const pastDue = billing.needs_payment_update;

  return `
    <h2 class="billing-head">
      Subscription <span class="pill ${pastDue ? "warn" : "ok"}">${pastDue ? "Payment failed" : "Active"}</span>
    </h2>
    ${pastDue
      ? `<p class="form-msg err">
           We couldn't charge your card. You're still receiving leads for now — update your
           card to avoid an interruption.
         </p>`
      : ""}
    <p class="billing-body">
      You're on the $25/month plan with unlimited leads.${renews ? ` Renews ${renews}.` : ""}
    </p>
    <button class="ghost-btn wide" id="manageBtn">
      ${pastDue ? "Update card" : "Manage or cancel subscription"}
    </button>
    <p class="fineprint">
      Opens your secure Stripe billing page, where you can update your card, download invoices,
      or cancel — takes effect at the end of the period you've paid for.
    </p>`;
}

async function startCheckout() {
  const btn = $("subscribeBtn");
  const consent = $("renewConsent");
  if (!consent || !consent.checked) return;   // belt-and-suspenders: never charge without consent
  btn.disabled = true; btn.textContent = "Opening secure checkout…";
  try {
    // Send the consent signal so the server can persist a dated record of it —
    // ARL requires keeping proof of consent for 3 years (1 year post-cancel).
    const resp = await authedFetch("/api/billing/checkout", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ renewalConsent: true }),
    });
    if (!resp.ok) throw new Error(`Couldn't start checkout (${resp.status}).`);
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
  show($("dashView"), false);
  show($("chatsView"), false);
  show($("tabs"), false);
  show($("signOutBtn"), true);
  const c = $("authView");
  c.hidden = false;
  c.innerHTML = `<h1>Nothing to manage here</h1><p class="muted">${esc(text)}</p>
    <button class="ghost-btn" onclick="location.reload()" style="margin-top:16px">Reload</button>`;
}

// No lead- or phone-matched business for this account. Rather than a dead-end
// "nothing to manage" screen, this is the start of setting a page up: name the
// business (that's all it takes to create an owned listing — method 6), then land
// straight in Settings to fill in the rest. See BUSINESS_CLAIM_PLAN.md.
function noBusiness() {
  show($("bootView"), false);
  show($("dashView"), false);
  show($("chatsView"), false);
  show($("editorView"), false);
  show($("tabs"), false);
  show($("signOutBtn"), true);
  const c = $("authView");
  c.hidden = false;
  c.innerHTML = `
    <h1>Set up your business page</h1>
    <p class="muted">Add your business, then fill in your services, prices, and photos.
      If a customer already reached you through Brightglow, sign in with that exact
      number or email to open your existing page instead.</p>
    <form id="createBizForm" style="margin-top:16px">
      <input id="newBizName" type="text" placeholder="Business name" autocomplete="organization" required>
      <input id="newBizWebsite" type="url" placeholder="Website (optional)" autocomplete="url">
      <input id="newBizPhone" type="tel" placeholder="Business phone (optional)" autocomplete="tel">
      <button type="submit" class="primary-btn wide" style="margin-top:12px">Continue to your page</button>
      <p id="createBizMsg" class="form-msg"></p>
    </form>`;
  $("createBizForm").addEventListener("submit", createBusiness);
}

async function createBusiness(e) {
  e.preventDefault();
  const msg = $("createBizMsg");
  const name = $("newBizName").value.trim();
  if (!name) return;
  msg.className = "form-msg"; msg.textContent = "";
  const btn = e.target.querySelector('button[type="submit"]');
  btn.disabled = true; btn.textContent = "Adding…";
  const { data: placeId, error } = await sb.rpc("create_business", {
    p_name: name,
    p_website: $("newBizWebsite").value.trim() || null,
    p_phone: $("newBizPhone").value.trim() || null,
  });
  if (error || !placeId) {
    btn.disabled = false; btn.textContent = "Continue to your page";
    msg.className = "form-msg err";
    msg.textContent = error ? error.message : "Couldn't create the business. Try again.";
    return;
  }
  // The new place is owned by you now — reload the list and land in Settings so the
  // next thing you see is your page, ready to fill in.
  landOnEditor = true;
  await enterDashboard();
}

// A phone-matched but unclaimed place shows a claim CTA (method 1). One tap writes
// ownership via claim_business(), so profile edits and leads stick to this account.
function renderClaimBanner() {
  show($("claimBanner"), !!(current && current.claimable));
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
  renderClaimBanner();
  return true;
}

async function claimCurrentBusiness() {
  if (!current) return;
  const btn = $("claimBtn");
  btn.disabled = true; btn.textContent = "Claiming…";
  const { data: ok, error } = await sb.rpc("claim_business", { p_place_id: current.place_id });
  btn.disabled = false; btn.textContent = "Claim this business";
  if (error || !ok) {
    alert(error ? ("Claim failed: " + error.message)
                : "We couldn't verify this business is yours from your phone number. " +
                  "If it's yours, contact hello@brightglow.co.");
    return;
  }
  current.claimable = false;
  renderClaimBanner();
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
  renderStats();
  renderSwitcher();
  renderClaimBanner();
  updateCompleteness();
}

// ── profile fields ──────────────────────────────────────────
function renderProfile() {
  $("bizName").textContent = profile.display_name || current.name;
  // bizMeta (city · readiness) is owned by updateCompleteness, which runs after
  // this and keeps the subtitle in sync as fields are filled in.
  $("displayName").value = profile.display_name || "";
  $("about").value = profile.about || "";
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
}

// Bind simple text fields → profile on input. Only the two the app's editor
// exposes; tagline/phone/website/service_area/license_number/years_in_business
// are no longer edited here, and their stored values ride through save untouched.
const FIELD_MAP = { displayName: "display_name", about: "about" };
for (const [id, key] of Object.entries(FIELD_MAP)) {
  document.addEventListener("input", (e) => {
    if (e.target.id !== id) return;
    profile[key] = e.target.value;
    if (id === "displayName") $("bizName").textContent = e.target.value || current.name;
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
    card.querySelector(".name-in").addEventListener("input", (e) => { setSvc(i, "name", e.target.value); });
    card.querySelector(".min-in").addEventListener("input", (e) => { setSvc(i, "price_min", numOrNull(e.target.value)); });
    card.querySelector(".max-in").addEventListener("input", (e) => { setSvc(i, "price_max", numOrNull(e.target.value)); });
    card.querySelector(".rm").addEventListener("click", () => {
      profile.services.splice(i, 1);
      // There's always one open service row — deleting the last leaves a fresh
      // blank rather than an empty section (same as the app).
      if (!profile.services.length) profile.services.push({ name: "", price_min: null, price_max: null, unit: "job" });
      renderServices(); markDirty(); updateCompleteness();
    });
  });
}

// One card per service, laid out like the app's ServiceRowEditor: the name on
// its own row, min/max side by side beneath it, then Delete. Not a spreadsheet
// row. `unit` isn't shown and stays at its "job" default in the model.
function serviceCardHTML(s, i) {
  return `<div class="service-card" data-i="${i}">
    <label class="field-label">Service</label>
    <input class="name-in" type="text" placeholder="Service name" value="${esc(s.name)}">
    <div class="price-pair">
      <div>
        <label class="field-label">Price min $</label>
        <input class="min-in" type="number" min="0" placeholder="$" value="${s.price_min ?? ""}">
      </div>
      <div>
        <label class="field-label">Price max $</label>
        <input class="max-in" type="number" min="0" placeholder="$" value="${s.price_max ?? ""}">
      </div>
    </div>
    <button type="button" class="ghost-btn rm">Delete</button>
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
    <div class="photo-cell" draggable="true" data-i="${i}">
      ${i === 0 ? '<span class="lead-badge">Leads</span>' : ""}
      <img src="${publicUrl(p)}" alt="">
      <button class="rm" data-i="${i}" title="Remove">×</button>
    </div>`).join("")
    + `<label class="photo-add" for="photoInput" title="Add photos"><span>+</span></label>`;
  strip.querySelectorAll(".rm").forEach((b) => b.addEventListener("click", (e) => {
    e.stopPropagation();
    profile.photos.splice(+b.dataset.i, 1); renderPhotos(); markDirty(); updateCompleteness();
  }));
  wirePhotoDrag(strip);
}

function wirePhotoDrag(grid) {
  let from = null;
  grid.querySelectorAll(".photo-cell").forEach((cell) => {
    cell.addEventListener("dragstart", () => { from = +cell.dataset.i; cell.classList.add("dragging"); });
    cell.addEventListener("dragend", () => cell.classList.remove("dragging"));
    cell.addEventListener("dragover", (e) => e.preventDefault());
    cell.addEventListener("drop", (e) => {
      e.preventDefault();
      const to = +cell.dataset.i;
      if (from === null || from === to) return;
      const arr = profile.photos;
      arr.splice(to, 0, arr.splice(from, 1)[0]);
      from = null; renderPhotos(); markDirty();
    });
  });
}

$("photoInput").addEventListener("change", async (e) => {
  const files = [...e.target.files];
  e.target.value = "";
  if (!files.length) return;
  const msg = $("photoMsg");
  msg.className = "form-msg"; msg.textContent = `Uploading ${files.length} photo(s)…`;
  try {
    for (const file of files) {
      const path = await uploadImage(file);
      (profile.photos ||= []).push(path);
    }
    msg.className = "form-msg ok"; msg.textContent = "Uploaded. Remember to Save.";
    renderPhotos(); markDirty(); updateCompleteness();
  } catch (err) {
    msg.className = "form-msg err"; msg.textContent = err.message || "Upload failed.";
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
    const last = msgs[msgs.length - 1];
    const waiting = !!last && last.direction === "outbound";
    // No manual truncation — .lead-preview ellipsises, and slicing escaped HTML
    // could cut an entity in half.
    const preview = last ? esc(last.body_text || "") : "New request — no messages yet";
    return `<div class="lead-card ${waiting ? "needs-reply" : ""}" data-i="${i}">
      <div class="lead-main">
        <div class="lead-title-row">
          <span class="lead-title">${esc(l.city || "New request")}</span>
          ${waiting ? `<span class="lead-pill">Reply needed</span>` : ""}
          <span class="lead-time">${fmtRelative((last && last.created_at) || l.created_at)}</span>
        </div>
        <div class="lead-preview ${waiting ? "is-waiting" : ""}">${preview}</div>
      </div>
      <button type="button" class="ghost-btn reply-btn">Open</button>
    </div>`;
  }).join("");
  list.querySelectorAll(".lead-card").forEach((card) =>
    card.addEventListener("click", () => openThread(leads[+card.dataset.i])));
}

const sortMsgs = (m) => m.slice().sort((a, b) => (a.created_at < b.created_at ? -1 : 1));

// ── one conversation ────────────────────────────────────────
let thread = null;   // the lead whose thread is open

async function openThread(lead) {
  thread = lead;
  $("threadTitle").textContent = lead.business_name || current.name;
  $("threadSub").textContent = [lead.city, fmtDate(lead.created_at)].filter(Boolean).join(" · ");
  $("threadMsg").textContent = "";
  show($("leadsCard"), false);
  show($("threadCard"), true);
  renderThread(sortMsgs(lead.messages || []));
  await refreshThread();
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
  if (!msgs.length) {
    box.innerHTML = `<p class="thread-empty">No messages yet — say hello.</p>`;
    return;
  }
  // Direction is stored relative to the CUSTOMER: "outbound" = customer→business
  // (theirs), "inbound" = business→customer (mine). See ChatModels.swift.
  box.innerHTML = msgs.map((m) => {
    const mine = m.direction === "inbound";
    return `<div class="bubble ${mine ? "mine" : "theirs"}">${esc(m.body_text || "")}
      <div class="bubble-time">${fmtTime(m.created_at)}</div></div>`;
  }).join("");
  box.scrollTop = box.scrollHeight;
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

// Named relative time ("yesterday", "3 days ago") to match the app's request
// rows, which use .relative(presentation: .named). Falls back to a short date
// past a month, where "34 days ago" stops being useful.
const RTF = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
function fmtRelative(iso) {
  if (!iso) return "";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "";
  const secs = Math.round((t - Date.now()) / 1000);
  const abs = Math.abs(secs);
  if (abs < 60) return RTF.format(secs, "second");
  if (abs < 3600) return RTF.format(Math.round(secs / 60), "minute");
  if (abs < 86400) return RTF.format(Math.round(secs / 3600), "hour");
  if (abs < 2592000) return RTF.format(Math.round(secs / 86400), "day");
  return fmtDate(iso);
}

// ── completeness meter ──────────────────────────────────────
// Kept in lockstep with the app's BusinessService.completeness (Swift): the SAME
// five checks, each worth 20%, so a business sees an identical readiness score on
// web and mobile. The web-only fields (phone, website, service area, license,
// tagline, years) deliberately don't count toward readiness — matching the native
// editor, which doesn't expose them at all.
function updateCompleteness() {
  const checks = [
    !!profile.display_name,
    !!profile.about,
    !!profile.logo_path,
    (profile.photos || []).length > 0,
    (profile.services || []).some((s) => s.name),
  ];
  const done = checks.filter(Boolean).length;
  const pct = Math.round((done / checks.length) * 100);
  const label = pct === 100 ? "Page complete" : `${pct}% complete`;
  // Readiness rides in the header subtitle exactly as it does in the app, and
  // the nudge card only appears while there's still something left to finish.
  $("bizMeta").textContent = [current && current.city, label].filter(Boolean).join(" · ");
  $("readinessPct").textContent = `${pct}%`;
  show($("readinessCard"), pct < 100);
}

// The dashboard counts (Figma 1611:7531): Views + Leads. Replies/"needs reply" is
// gone — conversations are handled in the app now, not this portal.
function renderStats() {
  const leads = current.leads || [];
  $("statRequests").textContent = leads.length;
  loadViews();
}

// Trailing-30-day profile views (business_profile_views). Owner-only under RLS,
// and purely decorative — a failure leaves the tile at 0 rather than surfacing.
async function loadViews() {
  const el = $("statViews");
  if (!el || !current?.place_id) return;
  const since = new Date(Date.now() - 30 * 864e5).toISOString().slice(0, 10);
  const { data, error } = await sb
    .from("business_profile_views")
    .select("views")
    .eq("place_id", current.place_id)
    .gte("day", since);
  if (error) return;
  el.textContent = (data || []).reduce((n, r) => n + (r.views || 0), 0);
}

// ── save ────────────────────────────────────────────────────
async function saveProfile() {
  if (!current || !profile) return;
  clearTimeout(autosaveTimer);
  // Claim-first: the business_profiles upsert policy is owns_business(place_id),
  // so a phone-matched place must be claimed before the first save or the write
  // is rejected by RLS. No-op for lead-matched / already-owned places.
  if (!(await ensureWritable())) { show($("saveFailed"), true); return; }
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
    // A successful autosave says nothing; a failed one has to, since there is no
    // Save button left to retry from.
    console.error("autosave failed:", error);
    show($("saveFailed"), true);
  } else {
    dirty = false;
    show($("saveFailed"), false);
    // reflect into the switcher label
    current.name = profile.display_name || current.name;
    renderSwitcher();
  }
}

// ── views + guards ──────────────────────────────────────────
// Dashboard and Settings are the two peer tabs. Billing is reached from Settings
// (leaving the strip on Settings), and "chats" is a viewable-but-untabbed thread
// opened only by a job-email `?lead=` deep link — it keeps the tab strip up so the
// owner can step back to Dashboard/Settings.
const TAB_VIEWS = ["chats", "dash", "editor"];

function showView(name) {
  show($("chatsView"), name === "chats");
  show($("dashView"), name === "dash");
  show($("editorView"), name === "editor");
  show($("billingView"), name === "billing");

  const active = name === "billing" ? "editor" : name;
  document.querySelectorAll(".tab").forEach((t) => {
    t.classList.toggle("is-active", t.dataset.view === active);
  });
  show($("tabs"), TAB_VIEWS.includes(name) || name === "billing");
  window.scrollTo(0, 0);
}

function openEditor() {
  $("signedInAs").textContent = signedInEmail ? `Signed in as ${signedInEmail}` : "";
  showView("editor");
}

async function signOut() {
  await sb.auth.signOut();
  location.reload();
}

// Permanent account deletion. Releases every business this owner holds (their
// listing reverts to its public info), removes their profile pages + claims, and
// deletes the login itself — then signs out for good. The browser's anon key
// CAN'T delete a Supabase auth user, so the actual removal runs in the
// `delete-account` Edge Function (service role); here we just invoke it and, on
// success, drop the local session and reload. Customer requests are preserved
// (they're keyed to the customer, not this owner).
async function deleteAccount() {
  if (!confirm(
    "Delete your account?\n\n" +
    "This permanently removes your business page and signs you out for good — you " +
    "won't be able to log in again with this phone or email. Your listing reverts to " +
    "its public info, and customer requests are kept. This cannot be undone."
  )) return;
  const btn = $("deletePageBtn");
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
  // The Dashboard / Settings tabs. (The stat tiles no longer carry jump buttons.)
  document.querySelectorAll("[data-view]").forEach((el) => {
    el.addEventListener("click", () => {
      const target = el.dataset.view;
      if (target === "editor") openEditor(); else showView(target);
    });
  });
  $("readinessCta").addEventListener("click", openEditor);
  $("editorBack")?.addEventListener("click", () => showView("dash"));
  $("billingBtn").addEventListener("click", () => showView("billing"));
  $("billingBack").addEventListener("click", () => showView("dash"));
  $("deletePageBtn").addEventListener("click", deleteAccount);
  $("claimBtn").addEventListener("click", claimCurrentBusiness);
  // Leaving inside the debounce window must not lose the edit. keepalive-style
  // flush: fire the save without awaiting, the same shape as the app's onDisappear.
  window.addEventListener("beforeunload", () => { if (dirty) saveProfile(); });
  $("retrySaveBtn").addEventListener("click", () => saveProfile());
}
