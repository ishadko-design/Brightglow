// Drop-in for the LeadBridge repo (Node on Railway).
//
// CAN-SPAM suppression list, backed by the `email_suppressions` table created in
// supabase/migrations/20260715000000_business_portal.sql. Every outbound send
// must check isSuppressed() first, and the one-click unsubscribe link writes via
// suppress(). Reads/writes use the SERVICE ROLE (RLS gives no client access to
// this table), which LeadBridge already has.
//
// Assumes an existing service-role Supabase client. If you don't already export
// one, this creates its own from env.

const { createClient } = require("@supabase/supabase-js");
const crypto = require("crypto");

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } }
);

const norm = (email) => (email || "").trim().toLowerCase();

// Deterministic, unguessable token for an address, so the unsubscribe link in an
// email needs no lookup table and can't be enumerated. Keep UNSUBSCRIBE_SECRET
// stable (set it once in Railway env) or existing links stop verifying.
function unsubscribeToken(email) {
  const secret = process.env.UNSUBSCRIBE_SECRET || "";
  return crypto.createHmac("sha256", secret).update(norm(email)).digest("hex").slice(0, 32);
}

// True when this address opted out (or hard-bounced/complained). Call before EVERY
// send; skip the send when true.
async function isSuppressed(email) {
  const { data, error } = await supa
    .from("email_suppressions")
    .select("email")
    .eq("email", norm(email))
    .maybeSingle();
  if (error) {
    // Fail OPEN would risk emailing an opted-out address; fail CLOSED (treat as
    // suppressed) on a hard error is the safer legal default.
    console.error("suppression check failed:", error.message);
    return true;
  }
  return !!data;
}

// Record an opt-out (idempotent). `reason` is 'unsubscribe' | 'bounce' | 'complaint'.
async function suppress(email, reason = "unsubscribe") {
  const row = { email: norm(email), reason, token: unsubscribeToken(email) };
  const { error } = await supa
    .from("email_suppressions")
    .upsert(row, { onConflict: "email" });
  if (error) throw new Error("suppress failed: " + error.message);
}

// Verify a token from an unsubscribe link matches the address (constant-time).
function tokenValid(email, token) {
  const expected = unsubscribeToken(email);
  const a = Buffer.from(expected);
  const b = Buffer.from(String(token || ""));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

module.exports = { isSuppressed, suppress, unsubscribeToken, tokenValid, norm };
