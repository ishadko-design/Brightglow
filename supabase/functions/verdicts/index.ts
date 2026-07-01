// Supabase Edge Function: `verdicts`
//
// Shared photo-screening verdicts (Phase 3). The app screens a place's photos
// on-device once and uploads which are work shots; other users read that verdict
// and skip screening. So a place's pool is downloaded for classification at most
// once across all users.
//
//   POST { op: "get", vertical, ids: [placeId, ...] }
//        -> { verdicts: { placeId: { kept: [url], scanned: n } } }  (fresh only)
//   POST { op: "put", vertical, id, kept: [url], scanned }
//        -> { ok: true }
//
// Deploy:  supabase functions deploy verdicts
// Table:   supabase/migrations/*_place_verdicts.sql
//
// NOTE: unauthenticated (verify_jwt = false) like `search`; hardening is Phase 4.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const FRESH_MS = 30 * 24 * 60 * 60 * 1000;   // verdicts valid for 30 days

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!db) return json({ error: "db not configured" }, 500);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const op = payload.op;
  const vertical = typeof payload.vertical === "string" ? payload.vertical : "home";

  if (op === "get") {
    const ids = Array.isArray(payload.ids) ? payload.ids.filter((x) => typeof x === "string") : [];
    if (ids.length === 0) return json({ verdicts: {} });
    const { data, error } = await db.from("place_verdicts")
      .select("place_id, kept, scanned, screened_at")
      .eq("vertical", vertical)
      .in("place_id", ids as string[]);
    if (error) return json({ verdicts: {} });   // best-effort
    const out: Record<string, unknown> = {};
    for (const row of data ?? []) {
      if (Date.now() - new Date(row.screened_at as string).getTime() < FRESH_MS) {
        out[row.place_id as string] = { kept: row.kept, scanned: row.scanned };
      }
    }
    return json({ verdicts: out });
  }

  if (op === "put") {
    const id = payload.id;
    const kept = payload.kept;
    const scanned = payload.scanned;
    if (typeof id !== "string" || !Array.isArray(kept) || typeof scanned !== "number") {
      return json({ error: "missing id / kept / scanned" }, 400);
    }
    const { error } = await db.from("place_verdicts").upsert({
      place_id: id,
      vertical,
      kept,
      scanned,
      screened_at: new Date().toISOString(),
    });
    if (error) return json({ error: "write failed" }, 500);
    return json({ ok: true });
  }

  return json({ error: "unknown op (use get|put)" }, 400);
});
