// Supabase Edge Function: `photo-embeddings`
//
// Serves meaning fingerprints (embeddings) for photo URLs, computing them
// on demand via the brightglow-embed Cloudflare Worker.
//
// The deployed `phototags` function writes tags to `photo_tags` (photo_name,
// place_id, tags) but no fingerprint. This function fills that gap without
// touching the working tagging pipeline:
//
//   POST { urls: [string], tags?: { <url>: [string] } }
//     -> { embeddings: { <url>: [number x384] } }
//
// For each URL:
//   1. If photo_tags has a fingerprint, return it.
//   2. Else if tags are available (from `tags` param or the DB row), embed
//      the description via the Worker, store it, and return it.
//   3. Else omit the URL (caller falls back to word matching).
//
// Fingerprints come from @cf/baai/bge-small-en-v1.5 (384 dims) — the same
// model the iOS app uses to embed the search query. Changing the model
// requires recomputing every stored fingerprint.
//
// Deploy:  supabase functions deploy photo-embeddings
// Secrets: APP_TOKEN (auth), SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (db),
//          EMBED_WORKER_URL, EMBED_WORKER_TOKEN (defaults to the production
//          brightglow-embed worker and its token).

import { createClient } from "jsr:@supabase/supabase-js@2";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WORKER_URL = Deno.env.get("EMBED_WORKER_URL") ??
  "https://brightglow-embed.igor-shadko.workers.dev/";
const WORKER_TOKEN = Deno.env.get("EMBED_WORKER_TOKEN") ?? "";

const DIMS = 384;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function embedText(text: string): Promise<number[] | null> {
  try {
    const res = await fetch(WORKER_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(WORKER_TOKEN ? { "x-app-token": WORKER_TOKEN } : {}),
      },
      body: JSON.stringify({ text }),
    });
    if (!res.ok) return null;
    const body = await res.json();
    const v = body?.embedding;
    if (!Array.isArray(v) || v.length !== DIMS) return null;
    return v;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!SUPABASE_URL || !SERVICE_KEY) {
    return json({ error: "photo-embeddings unavailable" }, 503);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }
  const urls = Array.isArray(payload.urls)
    ? payload.urls.filter((u): u is string => typeof u === "string").slice(0, 50)
    : [];
  if (urls.length === 0) return json({ embeddings: {} });
  const paramTags = (payload.tags ?? {}) as Record<string, string[]>;

  const db = createClient(SUPABASE_URL, SERVICE_KEY);
  const out: Record<string, number[]> = {};

  // Batch-fetch existing rows.
  const { data: rows } = await db.from("photo_tags")
    .select("photo_name, tags, embedding")
    .in("photo_name", urls);
  const byUrl = new Map((rows ?? []).map((r) => [r.photo_name as string, r]));

  for (const url of urls) {
    const row = byUrl.get(url);
    const existing = row?.embedding as number[] | null;
    if (Array.isArray(existing) && existing.length === DIMS) {
      out[url] = existing;
      continue;
    }
    // Need tags to describe the photo: prefer the request param (fresh from
    // phototags, avoids a read-after-write race), fall back to the DB row.
    const tags = (Array.isArray(paramTags[url]) && paramTags[url].length > 0)
      ? paramTags[url]
      : (Array.isArray(row?.tags) ? (row!.tags as string[]) : []);
    if (tags.length === 0) continue;
    const vec = await embedText(tags.join(", "));
    if (!vec) continue;
    out[url] = vec;
    // Persist for every future caller. Fire-and-forget: a failed write just
    // means the next call recomputes.
    db.from("photo_tags").upsert({
      photo_name: url,
      place_id: (row?.place_id as string | null) ?? null,
      tags,
      model: "bge-small-en-v1.5",
      tagged_at: new Date().toISOString(),
      embedding: vec,
    }, { onConflict: "photo_name" }).then(
      () => {},
      (e) => console.error("photo-embeddings: upsert failed", e),
    );
  }

  return json({ embeddings: out });
});
