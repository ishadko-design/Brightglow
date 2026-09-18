// Supabase Edge Function: `verdicts`
//
// Shared photo-screening verdicts (Phase 3). The app screens a place's photos
// on-device once and uploads which are work shots; other users read that verdict
// and skip screening. So a place's pool is downloaded for classification at most
// once across all users.
//
//   POST { op: "get", vertical, ids: [placeId, ...] }
//        -> { verdicts: { placeId: { kept: [url], scanned: n, enriched: bool } } }
//   POST { op: "put", vertical, id, kept: [url], scanned, enriched? }
//        -> { ok: true }
//
// `enriched` marks whether the kept photos carry rich vision tags (from the
// `phototags` function) or only generic on-device labels — the client re-enriches
// a verdict the first time it loads one that isn't enriched yet.
//
// Deploy:  supabase functions deploy verdicts
// Table:   supabase/migrations/*_place_verdicts.sql
//
// NOTE: unauthenticated (verify_jwt = false) like `search`; hardening is Phase 4.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { lookupStoredTags, photoNameFromUrl, TAG_VERSION } from "../_shared/photo-tagging.ts";

const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;
// Shared-token gate (Phase 4). Enforced only when APP_TOKEN is set — fail-open.
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";

const FRESH_MS = 30 * 24 * 60 * 60 * 1000;   // verdicts valid for 30 days

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
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

  const op = payload.op;
  const vertical = typeof payload.vertical === "string" ? payload.vertical : "home";

  if (op === "get") {
    const ids = Array.isArray(payload.ids) ? payload.ids.filter((x) => typeof x === "string") : [];
    if (ids.length === 0) return json({ verdicts: {} });
    const { data, error } = await db.from("place_verdicts")
      .select("place_id, kept, scanned, enriched, screened_at")
      .eq("vertical", vertical)
      .in("place_id", ids as string[]);
    if (error) return json({ verdicts: {} });   // best-effort
    const out: Record<string, unknown> = {};
    for (const row of data ?? []) {
      if (Date.now() - new Date(row.screened_at as string).getTime() < FRESH_MS) {
        out[row.place_id as string] = {
          kept: row.kept, scanned: row.scanned, enriched: row.enriched ?? false,
        };
      }
    }
    // Union server-side vision tags into each kept photo's labels. Tags are
    // stored globally per photo (any user, either vertical), so even a stale
    // or never-enriched verdict serves "furnace"-level labels the moment any
    // tagging path has covered its photos — no client change needed for the
    // ranking to start seeing them.
    const urlToKey = new Map<string, string>();
    try {
      for (const v of Object.values(out)) {
        const kept = (v as { kept?: unknown }).kept;
        if (!Array.isArray(kept)) continue;
        for (const k of kept) {
          const url = typeof k === "string" ? k : (k as { url?: unknown })?.url;
          if (typeof url === "string" && url && !urlToKey.has(url)) {
            urlToKey.set(url, photoNameFromUrl(url) ?? url);
          }
        }
      }
      const stored = await lookupStoredTags(db, [...urlToKey.values()]);
      if (Object.keys(stored).length > 0) {
        for (const v of Object.values(out)) {
          const kept = (v as { kept?: unknown }).kept;
          if (!Array.isArray(kept)) continue;
          for (const k of kept) {
            if (typeof k !== "object" || k === null) continue;
            const entry = k as { url?: unknown; labels?: unknown };
            if (typeof entry.url !== "string") continue;
            const extra = stored[urlToKey.get(entry.url) ?? ""];
            if (!extra || extra.length === 0) continue;
            const labels = Array.isArray(entry.labels) ? entry.labels.map(String) : [];
            entry.labels = [...new Set([...labels, ...extra])];
          }
        }
      }
    } catch (err) {
      console.error("verdicts: tag merge failed", err);  // best-effort; verdicts still served
    }
    // A verdict only counts as enriched if its kept photos actually carry
    // current-version vision tags. Older clients marked enriched=true even
    // when the tagger added nothing, which wedged those verdicts on generic
    // on-device labels forever — the client never retries an enriched
    // verdict, so photo-evidence ranking could never fire for them.
    // Recompute from the tag store (version-aware, like phototags'
    // cache-skip) instead of trusting the stored flag.
    try {
      const current = await lookupStoredTags(db, [...urlToKey.values()], TAG_VERSION);
      for (const v of Object.values(out)) {
        const entry = v as { kept?: unknown; enriched?: boolean };
        const kept = entry.kept;
        if (!Array.isArray(kept) || kept.length === 0) continue;
        const allTagged = kept.every((k) => {
          const url = typeof k === "string" ? k : (k as { url?: unknown })?.url;
          if (typeof url !== "string" || !url) return false;
          return current[urlToKey.get(url) ?? ""] !== undefined;
        });
        if (!allTagged) entry.enriched = false;
      }
    } catch (err) {
      console.error("verdicts: enriched recompute failed", err);  // best-effort; stored flag stands
    }
    return json({ verdicts: out });
  }

  if (op === "put") {
    const id = payload.id;
    const kept = payload.kept;
    const scanned = payload.scanned;
    const enriched = payload.enriched === true;
    if (typeof id !== "string" || !Array.isArray(kept) || typeof scanned !== "number") {
      return json({ error: "missing id / kept / scanned" }, 400);
    }
    const { error } = await db.from("place_verdicts").upsert({
      place_id: id,
      vertical,
      kept,
      scanned,
      enriched,
      screened_at: new Date().toISOString(),
    });
    if (error) return json({ error: "write failed" }, 500);
    return json({ ok: true });
  }

  return json({ error: "unknown op (use get|put)" }, 400);
});
