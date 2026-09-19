// Supabase Edge Function: `attribution`
//
// Apple Ads install attribution via the AdServices token exchange.
//
// The app captures AAAttribution.attributionToken() on first launch and POSTs
// { device_id, attribution_token } here. This function exchanges the token with
// Apple (POST https://api-adservices.apple.com/api/v1/, raw token as text/plain
// body, no auth — the token itself is the credential) and stores the result in
// `ad_attributions`, keyed by device_id so it joins with leads.sender_device_id
// for cost-per-sender-per-keyword math.
//
// First-write-wins: one row per device; a repeat report for the same device is
// a no-op (deduped). The raw token is single-use and expires 24h after Apple
// mints it, so it is nulled out as soon as Apple answers — only the sha256
// fingerprint is kept for idempotency. Apple's attribution record can take up
// to ~24h to exist after install (the endpoint 404s until then), so 404s and
// 5xx keep the row 'pending' with the token intact; the admin retry path below
// flushes them inside the token window.
//
// Endpoints (all POST; OPTIONS answers CORS):
//   { device_id, attribution_token }  header x-app-token: <secret>
//        -> { ok: true, status, deduped? }            (HTTP 200 once stored;
//           the app marks "reported" on any 200)
//   { retry_pending: true }           header x-admin-secret: <secret>
//        -> { ok: true, retried, attributed, organic, still_pending }
//
// Deploy:
//   supabase functions deploy attribution --no-verify-jwt
//   supabase secrets set APP_TOKEN=<redacted> ADMIN_SECRET=<redacted>
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const ADMIN_SECRET = Deno.env.get("ADMIN_SECRET") ?? "";
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

// Identical to the analytics function.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-admin-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

const APPLE_URL = "https://api-adservices.apple.com/api/v1/";
const APPLE_TIMEOUT_MS = 10_000;
const RETRY_404_ATTEMPTS = 3; // immediate in-request retries (Apple 404s until ready)
const RETRY_404_SLEEP_MS = 3_000;
const ADMIN_MAX_ATTEMPTS = 10; // stop re-flushing a token Apple never answers
const ADMIN_WINDOW_HOURS = 36; // only retry tokens still plausibly inside their 24h life

type AttrRow = {
  device_id: string;
  token_sha256: string;
  token: string | null;
  status: string;
  attempts: number;
  last_error: string | null;
  created_at: string;
  resolved_at: string | null;
};

async function sha256Hex(s: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function num(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

type AppleResult =
  | { kind: "attributed"; data: Record<string, unknown> }
  | { kind: "organic" }
  | { kind: "not_ready" } // 404 after retries — the record isn't live yet
  | { kind: "failed"; error: string } // other 4xx — don't retry
  | { kind: "error"; error: string }; // 5xx / network — retryable later

/// Exchange one token with Apple. Never throws: every outcome is a value.
async function exchangeWithApple(token: string): Promise<AppleResult> {
  for (let attempt = 0; attempt < RETRY_404_ATTEMPTS; attempt++) {
    if (attempt > 0) await sleep(RETRY_404_SLEEP_MS);
    let res: Response;
    try {
      res = await fetch(APPLE_URL, {
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body: token, // raw token string; NO auth headers — the token is the credential
        signal: AbortSignal.timeout(APPLE_TIMEOUT_MS),
      });
    } catch (err) {
      return { kind: "error", error: `apple_network_error: ${err instanceof Error ? err.message : String(err)}` };
    }
    // 404 = Apple's record isn't ready yet (can take up to ~24h post-install):
    // sleep and try again rather than calling it organic.
    if (res.status === 404) continue;
    if (res.status >= 500) return { kind: "error", error: `apple_http_${res.status}` };
    if (res.status !== 200) return { kind: "failed", error: `apple_http_${res.status}` };
    let body: Record<string, unknown>;
    try {
      body = await res.json();
    } catch {
      return { kind: "failed", error: "apple_bad_json" };
    }
    if (body["attribution"] === true) return { kind: "attributed", data: body };
    if (body["attribution"] === false) return { kind: "organic" };
    return { kind: "failed", error: "apple_unexpected_body" };
  }
  return { kind: "not_ready" };
}

/// Run the Apple exchange for a pending row and persist the outcome.
/// Returns the row's new status. The raw token is kept ONLY while the row is
/// still pending (Apple hasn't answered); every terminal state nulls it.
async function applyResolution(row: AttrRow): Promise<string> {
  const result = await exchangeWithApple(row.token as string);
  const patch: Record<string, unknown> = {};
  let status: string;
  switch (result.kind) {
    case "attributed": {
      status = "attributed";
      const d = result.data;
      patch.org_id = num(d["orgId"]);
      patch.campaign_id = num(d["campaignId"]);
      patch.ad_group_id = num(d["adGroupId"]);
      patch.keyword_id = num(d["keywordId"]);
      patch.keyword = typeof d["keyword"] === "string" ? d["keyword"] : null;
      patch.ad_id = num(d["adId"]);
      patch.country_or_region = typeof d["countryOrRegion"] === "string" ? d["countryOrRegion"] : null;
      patch.conversion_type = typeof d["conversionType"] === "string" ? d["conversionType"] : null;
      patch.click_at = typeof d["clickDate"] === "string" ? d["clickDate"] : null;
      patch.token = null;
      patch.resolved_at = new Date().toISOString();
      patch.last_error = null;
      break;
    }
    case "organic":
      status = "organic";
      patch.token = null;
      patch.resolved_at = new Date().toISOString();
      patch.last_error = null;
      break;
    case "not_ready":
      status = "pending";
      patch.attempts = row.attempts + 1;
      patch.last_error = "apple_404_not_ready";
      break;
    case "error":
      status = "pending";
      patch.attempts = row.attempts + 1;
      patch.last_error = result.error;
      break;
    case "failed":
      status = "failed";
      patch.token = null;
      patch.resolved_at = new Date().toISOString();
      patch.last_error = result.error;
      break;
  }
  patch.status = status;
  const { error } = await db!.from("ad_attributions").update(patch).eq("device_id", row.device_id);
  if (error) throw new Error(`db update failed: ${error.message}`);
  return status;
}

/// Admin flush: resolve every pending row whose token is still plausibly alive.
/// Call from a cron or manually inside the 24h token window.
async function retryPending(): Promise<Record<string, unknown>> {
  const cutoff = new Date(Date.now() - ADMIN_WINDOW_HOURS * 3_600_000).toISOString();
  const { data, error } = await db!.from("ad_attributions")
    .select("*")
    .eq("status", "pending")
    .lt("attempts", ADMIN_MAX_ATTEMPTS)
    .gte("created_at", cutoff)
    .not("token", "is", null)
    .order("created_at", { ascending: true })
    .limit(100);
  if (error) return { error: error.message };
  let attributed = 0;
  let organic = 0;
  let still_pending = 0;
  for (const row of (data ?? []) as AttrRow[]) {
    try {
      const status = await applyResolution(row);
      if (status === "attributed") attributed++;
      else if (status === "organic") organic++;
      else still_pending++;
    } catch (err) {
      console.error("attribution: retry failed for", row.device_id, err);
      still_pending++;
    }
  }
  return { ok: true, retried: (data ?? []).length, attributed, organic, still_pending };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!db) return json({ error: "db not configured" }, 500);

  // Admin retry path — the admin secret alone is sufficient (it is the
  // stronger credential; the app-token gate below is for app clients).
  const isAdmin = !!ADMIN_SECRET && req.headers.get("x-admin-secret") === ADMIN_SECRET;

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  if (isAdmin && body["retry_pending"] === true) {
    return json(await retryPending());
  }

  // App client path — same x-app-token check as the pricing function.
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }

  const device_id = typeof body["device_id"] === "string" ? body["device_id"].trim() : "";
  const attribution_token = typeof body["attribution_token"] === "string" ? body["attribution_token"].trim() : "";
  if (!device_id || !attribution_token) {
    return json({ error: "device_id and attribution_token required" }, 400);
  }
  if (device_id.length > 128 || attribution_token.length > 4096) {
    return json({ error: "device_id or attribution_token too long" }, 400);
  }

  // First-write-wins: an existing row means this device already reported.
  const { data: existing, error: selErr } = await db.from("ad_attributions")
    .select("device_id, status").eq("device_id", device_id).maybeSingle();
  if (selErr) return json({ error: selErr.message }, 500);
  if (existing) return json({ ok: true, deduped: true, status: (existing as AttrRow).status });

  const token_sha256 = await sha256Hex(attribution_token);
  const { error: insErr } = await db.from("ad_attributions").insert({
    device_id,
    token_sha256,
    token: attribution_token,
    status: "pending",
    attempts: 0,
  });
  if (insErr) {
    // Lost a race with a concurrent report for the same device — deduped.
    if (insErr.code === "23505") return json({ ok: true, deduped: true, status: "pending" });
    return json({ error: insErr.message }, 500);
  }

  // The row is stored; now attempt the Apple exchange inline. Any failure
  // below leaves the row 'pending' with the token intact for the admin retry.
  let status: string;
  try {
    status = await applyResolution({
      device_id,
      token_sha256,
      token: attribution_token,
      status: "pending",
      attempts: 0,
      last_error: null,
      created_at: new Date().toISOString(),
      resolved_at: null,
    });
  } catch (err) {
    console.error("attribution: resolution failed after insert", err);
    return json({ ok: true, status: "pending" });
  }
  return json({ ok: true, status });
});
