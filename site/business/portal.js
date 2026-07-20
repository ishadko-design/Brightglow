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

// Indicative service templates, mirrored from the app (Brightglow/Models/Types.swift
// priceTiers) so a business can seed sensible rows in one click, then edit.
const TRADE_TEMPLATES = {
  "Plumbing":        [["Minor fix",100,250],["Mid repair",400,900],["Full replacement",1000,3000]],
  "Electrical":      [["Outlet / fixture",80,200],["Panel work",400,1000],["Full rewire",3000,8000]],
  "HVAC":            [["Tune-up",100,250],["Repair",300,800],["Full install",3000,7000]],
  "Painting":        [["Single room",200,600],["Full interior",1500,4000],["Exterior",3000,9000]],
  "Carpentry":       [["Small repair",150,400],["Custom build",800,3500],["Full remodel",5000,15000]],
  "Roofing":         [["Patch / repair",300,800],["Partial replace",3000,7000],["Full roof",8000,20000]],
  "Flooring":        [["Single room",500,1500],["Whole floor",2000,6000],["Full home",8000,20000]],
  "Windows & Doors": [["Single unit",300,800],["Multiple units",1500,4000],["Full install",5000,12000]],
  "Landscaping":     [["Lawn / cleanup",100,400],["Garden redesign",1500,5000],["Full landscape",8000,25000]],
  "Mold & Pest Control": [["Single treatment",150,400],["Mold remediation",1000,4000],["Full fumigation",2000,6000]],
};

// ── element helpers ─────────────────────────────────────────
const $ = (id) => document.getElementById(id);
const show = (el, on = true) => { el.hidden = !on; };
const esc = (s) => (s ?? "").replace(/[&<>"']/g, (c) => (
  { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// ── app state ───────────────────────────────────────────────
let businesses = [];      // [{ place_id, name, city, leads: [...] }]
let current = null;       // the selected business
let profile = null;       // its business_profiles row (working copy)
let dirty = false;
const markDirty = () => { dirty = true; $("saveState").textContent = "Unsaved changes"; };

// ── boot ────────────────────────────────────────────────────
(async function boot() {
  wireStaticHandlers();
  const { data: { session } } = await sb.auth.getSession();
  if (session) await enterDashboard();
  else enterAuth();
})();

function enterAuth() {
  show($("bootView"), false);
  show($("dashView"), false);
  show($("signOutBtn"), false);
  show($("authView"), true);
}

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
  btn.disabled = false; btn.textContent = "Send sign-in link";
  if (error) {
    console.error("signInWithOtp failed:", error);   // full object for diagnosis
    msg.className = "form-msg err";
    msg.textContent = authErrorText(error);
  } else {
    msg.className = "form-msg ok";
    msg.textContent = `Check ${email} for a sign-in link, or enter the 6-digit code below.`;
    show($("codeForm"), true);
    $("code").focus();
  }
});

// Code fallback: verify the 6-digit OTP the same email carries. Works when the
// magic link won't (rewritten/pre-fetched by an email client, or the template
// only sends a code). On success detectSessionInUrl is irrelevant — verifyOtp
// establishes the session directly, so we can enter the dashboard.
$("codeForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = $("email").value.trim().toLowerCase();
  const token = $("code").value.trim();
  const msg = $("authMsg");
  if (!email || !token) return;
  const btn = $("verifyCodeBtn");
  btn.disabled = true; btn.textContent = "Verifying…";
  const { error } = await sb.auth.verifyOtp({ email, token, type: "email" });
  btn.disabled = false; btn.textContent = "Verify & sign in";
  if (error) {
    console.error("verifyOtp failed:", error);
    msg.className = "form-msg err";
    msg.textContent = /expired|invalid|token/i.test(error?.message || "")
      ? "That code is wrong or expired. Request a new link and try again."
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

$("signOutBtn").addEventListener("click", async () => {
  await sb.auth.signOut();
  location.reload();
});

// ── dashboard load ──────────────────────────────────────────
async function enterDashboard() {
  show($("authView"), false);
  show($("bootView"), true);

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
  businesses = [...byPlace.values()];

  if (businesses.length === 0) {
    fail("We couldn't match a claimable business to this email yet. If you received a Brightglow request at this address, reply to it or contact hello@brightglow.co.");
    return;
  }

  populateTradeSelect();

  // ?lead=<public_id> — the "Claim profile" button in a job email carries the
  // lead it's about, so open THAT business on Requests rather than dumping the
  // owner on a generic page and making them hunt for the job.
  const wantLead = new URLSearchParams(location.search).get("lead");
  const target = wantLead
    ? businesses.find((b) => b.leads.some((l) => l.public_id === wantLead))
    : null;
  await selectBusiness(target || businesses[0]);
  if (target) {
    openTab("leads");
    const lead = target.leads.find((l) => l.public_id === wantLead);
    if (lead) await openThread(lead);   // straight into the conversation
  }

  show($("bootView"), false);
  show($("dashView"), true);
  show($("signOutBtn"), true);
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
  if (!billing || !billing.enabled) { show($("billingTab"), false); return; }
  show($("billingTab"), true);
  renderBilling();

  // Coming back from Stripe (?billing=success|cancelled) — land on Billing so
  // the outcome is the first thing seen, rather than the profile editor.
  if (new URLSearchParams(location.search).get("billing")) openTab("billing");
}

function renderBilling() {
  const el = $("billingState");
  const flash = billingFlash();
  el.innerHTML = flash + (billing.subscribed ? subscribedHTML() : unsubscribedHTML());
  const sub = $("subscribeBtn");
  if (sub) sub.addEventListener("click", startCheckout);
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
    <button class="primary-btn wide" id="subscribeBtn">Subscribe</button>
    <p class="fineprint">
      $25 per month, charged to your card today and automatically on the same day each month
      until you cancel. <strong>Cancel anytime in one click</strong> from this page — no phone
      call, no email. See our <a href="../business-terms.html">Business Terms</a>.
    </p>`;
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
  btn.disabled = true; btn.textContent = "Opening secure checkout…";
  try {
    const resp = await authedFetch("/api/billing/checkout", { method: "POST" });
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

function fail(text) {
  show($("bootView"), false);
  show($("dashView"), false);
  show($("signOutBtn"), true);
  const c = $("authView");
  c.hidden = false;
  c.innerHTML = `<h1>Nothing to manage here</h1><p class="muted">${esc(text)}</p>
    <button class="ghost-btn" onclick="location.reload()" style="margin-top:16px">Reload</button>`;
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
  if (dirty && !confirm("Discard unsaved changes?")) return;
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
  $("saveState").textContent = "";
  thread = null;                      // a thread from the previous business
  show($("threadCard"), false);
  show($("leadsCard"), true);
  renderProfile();
  renderServices();
  renderPhotos();
  renderLeads();
  renderSwitcher();
  updateCompleteness();
}

// ── profile fields ──────────────────────────────────────────
function renderProfile() {
  $("bizName").textContent = profile.display_name || current.name;
  $("bizMeta").textContent = [current.city, current.place_id ? "Claimed page" : ""].filter(Boolean).join(" · ");
  $("displayName").value = profile.display_name || "";
  $("tagline").value = profile.tagline || "";
  $("about").value = profile.about || "";
  $("phone").value = profile.phone || "";
  $("website").value = profile.website || "";
  $("serviceArea").value = profile.service_area || "";
  $("license").value = profile.license_number || "";
  $("years").value = profile.years_in_business ?? "";
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

// Bind simple text fields → profile on input.
const FIELD_MAP = {
  displayName: "display_name", tagline: "tagline", about: "about",
  phone: "phone", website: "website", serviceArea: "service_area",
  license: "license_number",
};
for (const [id, key] of Object.entries(FIELD_MAP)) {
  document.addEventListener("input", (e) => {
    if (e.target.id !== id) return;
    profile[key] = e.target.value;
    if (id === "displayName") $("bizName").textContent = e.target.value || current.name;
    markDirty(); updateCompleteness();
  });
}
$("years").addEventListener("input", (e) => {
  profile.years_in_business = e.target.value === "" ? null : parseInt(e.target.value, 10);
  markDirty();
});
$("licensed").addEventListener("change", (e) => { profile.licensed = e.target.checked; markDirty(); });
$("insured").addEventListener("change", (e) => { profile.insured = e.target.checked; markDirty(); updateCompleteness(); });
$("acceptingWork").addEventListener("change", (e) => { profile.accepting_work = e.target.checked; markDirty(); });

// ── services editor ─────────────────────────────────────────
function populateTradeSelect() {
  const sel = $("tradePrefill");
  for (const trade of Object.keys(TRADE_TEMPLATES)) {
    const o = document.createElement("option");
    o.value = trade; o.textContent = trade; sel.appendChild(o);
  }
}

function renderServices() {
  const wrap = $("serviceRows");
  const rows = (profile.services || []);
  wrap.innerHTML = `<div class="service-head">
      <span>Service</span><span>Min $</span><span>Max $</span><span class="unit-col">Per</span><span></span>
    </div>` + rows.map((s, i) => serviceRowHTML(s, i)).join("");
  wrap.querySelectorAll(".service-row").forEach((row) => {
    const i = +row.dataset.i;
    row.querySelector(".name-in").addEventListener("input", (e) => { setSvc(i, "name", e.target.value); });
    row.querySelector(".min-in").addEventListener("input", (e) => { setSvc(i, "price_min", numOrNull(e.target.value)); });
    row.querySelector(".max-in").addEventListener("input", (e) => { setSvc(i, "price_max", numOrNull(e.target.value)); });
    row.querySelector(".unit-in").addEventListener("input", (e) => { setSvc(i, "unit", e.target.value); });
    row.querySelector(".rm").addEventListener("click", () => { profile.services.splice(i, 1); renderServices(); markDirty(); updateCompleteness(); });
  });
}

function serviceRowHTML(s, i) {
  return `<div class="service-row" data-i="${i}">
    <input class="name-in" type="text" placeholder="e.g. Drain cleaning" value="${esc(s.name)}">
    <input class="min-in" type="number" min="0" placeholder="—" value="${s.price_min ?? ""}">
    <input class="max-in" type="number" min="0" placeholder="—" value="${s.price_max ?? ""}">
    <input class="unit-in" type="text" placeholder="job" value="${esc(s.unit || "")}">
    <button class="rm" title="Remove" aria-label="Remove">×</button>
  </div>`;
}
const setSvc = (i, k, v) => { profile.services[i][k] = v; markDirty(); if (k === "name") updateCompleteness(); };
const numOrNull = (v) => (v === "" ? null : Number(v));

$("addServiceBtn").addEventListener("click", () => {
  (profile.services ||= []).push({ name: "", price_min: null, price_max: null, unit: "job" });
  renderServices(); markDirty();
});
$("prefillBtn").addEventListener("click", () => {
  const trade = $("tradePrefill").value;
  if (!trade) return;
  const tmpl = TRADE_TEMPLATES[trade].map(([name, mn, mx]) => ({ name, price_min: mn, price_max: mx, unit: "job" }));
  profile.services = [...(profile.services || []), ...tmpl];
  renderServices(); markDirty(); updateCompleteness();
});

// ── photos ──────────────────────────────────────────────────
function publicUrl(path) {
  return sb.storage.from(PHOTO_BUCKET).getPublicUrl(path).data.publicUrl;
}

function renderPhotos() {
  const grid = $("photoGrid");
  const photos = profile.photos || [];
  grid.innerHTML = photos.map((p, i) => `
    <div class="photo-cell" draggable="true" data-i="${i}">
      ${i === 0 ? '<span class="lead-badge">Leads</span>' : ""}
      <img src="${publicUrl(p)}" alt="">
      <button class="rm" data-i="${i}" title="Remove">×</button>
    </div>`).join("");
  grid.querySelectorAll(".rm").forEach((b) => b.addEventListener("click", (e) => {
    e.stopPropagation();
    profile.photos.splice(+b.dataset.i, 1); renderPhotos(); markDirty(); updateCompleteness();
  }));
  wirePhotoDrag(grid);
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
    // "inbound" = business→customer, so its presence means we already replied.
    const replied = msgs.some((m) => m.direction === "inbound");
    const preview = last ? esc(last.body_text || "").slice(0, 80) : "New request — no messages yet";
    return `<div class="lead-card" data-i="${i}">
      <div class="lead-main">
        <div class="lead-title">${esc(l.business_name || current.name)}
          <span class="lead-status ${replied ? "replied" : "new"}">${replied ? "Replied" : "New"}</span></div>
        <div class="lead-preview">${preview}</div>
        <div class="lead-meta">${esc(l.city || "")}${l.city ? " · " : ""}${fmtDate(l.created_at)}</div>
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
$("composer").addEventListener("submit", async (e) => {
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
  $("completeFill").style.width = pct + "%";
  $("completeText").textContent = pct === 100 ? "Page complete" : `${pct}% complete`;
}

// ── save ────────────────────────────────────────────────────
$("saveBtn").addEventListener("click", async () => {
  const btn = $("saveBtn");
  btn.disabled = true; $("saveState").textContent = "Saving…";
  const row = {
    place_id: current.place_id,
    display_name: profile.display_name || null,
    tagline: profile.tagline || null,
    about: profile.about || null,
    phone: profile.phone || null,
    website: profile.website || null,
    services: (profile.services || []).filter((s) => (s.name || "").trim()),
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
  btn.disabled = false;
  if (error) {
    $("saveState").textContent = "";
    alert("Save failed: " + (error.message || "unknown error"));
  } else {
    dirty = false;
    $("saveState").textContent = "All changes saved ✓";
    // reflect into the switcher label
    current.name = profile.display_name || current.name;
    renderSwitcher();
  }
});

// ── tabs + guards ───────────────────────────────────────────
function openTab(name) {
  document.querySelectorAll(".tab").forEach((x) => x.classList.toggle("is-active", x.dataset.tab === name));
  document.querySelectorAll(".tab-panel").forEach((p) => p.classList.toggle("is-active", p.dataset.panel === name));
}

function wireStaticHandlers() {
  document.querySelectorAll(".tab").forEach((t) =>
    t.addEventListener("click", () => openTab(t.dataset.tab)));
  window.addEventListener("beforeunload", (e) => {
    if (dirty) { e.preventDefault(); e.returnValue = ""; }
  });
}
