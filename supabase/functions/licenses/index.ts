// Supabase Edge Function: `licenses`
//
// Answers "does this business hold an active contractor licence?" for a batch of
// businesses, matched by phone number.
//
//   POST { phones: ["4156522093", ...] }
//        -> { licenses: { "4156522093": { licenseNo, classifications } } }
//
// Only ACTIVE licences are returned (CLEAR status, not past expiry — see the
// `is_active` column). A phone absent from the response means "no active
// California licence on file", which is NOT the same as "unlicensed": CSLB
// covers California only, and a business may be listed under a different phone.
// The client must therefore treat absence as "unknown" and show nothing.
//
// Deploy:  supabase functions deploy licenses
// Table:   supabase/migrations/*_cslb_licenses.sql (loaded by scripts/import-cslb.ts)
//
// NOTE: unauthenticated (verify_jwt = false) like `search` / `verdicts`.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;
// Shared-token gate. Enforced only when APP_TOKEN is set — fail-open.
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";

// One results page is ~20 businesses; cap well above that but bound the query.
const MAX_PHONES = 60;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Exactly 10 digits, or null — must match the importer's normalization. */
function normalizePhone(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 10) return digits;
  if (digits.length === 11 && digits.startsWith("1")) return digits.slice(1);
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!db) return json({ error: "db not configured" }, 500);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const raw = Array.isArray(payload.phones) ? payload.phones : [];
  const phones = [...new Set(raw.map(normalizePhone).filter((p): p is string => p !== null))]
    .slice(0, MAX_PHONES);
  if (phones.length === 0) return json({ licenses: {} });

  const { data, error } = await db.from("cslb_licenses")
    .select("phone, license_no, classifications")
    .eq("is_active", true)
    .in("phone", phones);
  // Best-effort, like `verdicts`: a failure just means no badges this time.
  if (error) return json({ licenses: {} });

  // ~3% of phones back more than one licence (a contractor holding several).
  // Any active one justifies the badge, so first wins.
  const out: Record<string, unknown> = {};
  for (const row of data ?? []) {
    const phone = row.phone as string;
    if (out[phone]) continue;
    out[phone] = { licenseNo: row.license_no, classifications: row.classifications };
  }
  return json({ licenses: out });
});
