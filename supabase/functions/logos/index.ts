// Supabase Edge Function: `logos`
//
// Resolves a contractor's logo ONCE per business and hosts a normalized copy in
// the public `business-logos` bucket, so every subsequent lookup — for any user —
// reuses the cached row instead of re-resolving. Same eventually-consistent,
// resolve-once, cross-user-shared pattern as `verdicts` / `phototags`.
//
// POST { op: "get", items: [{ place_id, website? }] }
//   -> { logos: { <place_id>: "<public url>" } }   // only businesses WITH a logo
//
// Cost design (this is the whole point):
//   - Resolve-once + negative cache: a business whose row has `logo_checked_at`
//     set is never resolved again — including misses (`logo_source='none'`), the
//     common case for small contractors with no site. This is the biggest lever.
//   - On-demand: the client only calls this for businesses it actually shows.
//   - Normalize to a tiny 256px PNG at ingest → ~5-15KB regardless of source, so
//     storage is negligible and per-view egress is small.
//   - Public bucket + long immutable cache-control: the client reads the logo
//     straight from the CDN URL (see LogoService.swift); repeat views hit cache,
//     not origin egress. No Edge invocation per view.
//   - The "no logo" case costs nothing extra: nothing is stored and the client
//     draws a name monogram.
//
// Resolve chain (avatar-appropriate: square brand marks before wide banners):
//   Brandfetch (only if BRANDFETCH_CLIENT_ID set) -> apple-touch-icon ->
//   <link rel=icon> (largest) -> og:image -> Google favicon service.
// First source whose bytes decode wins.
//
// Deploy:  supabase functions deploy logos
// Secrets: APP_TOKEN (shared), SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (auto),
//          BRANDFETCH_CLIENT_ID (optional — enables the Brandfetch source).

import { createClient } from "jsr:@supabase/supabase-js@2";
import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BRANDFETCH_CLIENT_ID = Deno.env.get("BRANDFETCH_CLIENT_ID") ?? "";

const BUCKET = "business-logos";
const MAX_ITEMS = 20;                 // bound per-call work
const LOGO_PX = 256;                  // normalized square-max edge
const MAX_SOURCE_BYTES = 3 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 5000;
const CACHE_CONTROL = "31536000";     // 1 year; logos are immutable once resolved

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function publicUrl(path: string): string {
  return `${SUPA_URL}/storage/v1/object/public/${BUCKET}/${path}`;
}

// Bare registrable host for favicon/Brandfetch lookups (drops scheme, path, www).
function domainOf(website: string): string | null {
  try {
    const u = new URL(website.includes("://") ? website : `https://${website}`);
    return u.hostname.replace(/^www\./, "") || null;
  } catch {
    return null;
  }
}

async function fetchBytes(url: string): Promise<Uint8Array | null> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const resp = await fetch(url, {
      signal: ctrl.signal,
      redirect: "follow",
      headers: { "User-Agent": "BrightglowLogoBot/1.0" },
    });
    if (!resp.ok) return null;
    const buf = new Uint8Array(await resp.arrayBuffer());
    return buf.byteLength > 0 && buf.byteLength <= MAX_SOURCE_BYTES ? buf : null;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

async function fetchText(url: string): Promise<string | null> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const resp = await fetch(url, {
      signal: ctrl.signal,
      redirect: "follow",
      headers: { "User-Agent": "BrightglowLogoBot/1.0" },
    });
    if (!resp.ok) return null;
    return await resp.text();
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

// Pull candidate icon/image URLs out of a page's <head>, resolved to absolute.
// Ordered most-logo-like first: apple-touch-icon, then sized rel=icon links
// (largest wins), then og:image / twitter:image as a last on-page resort.
function iconCandidates(html: string, baseUrl: string): string[] {
  const abs = (href: string): string | null => {
    try { return new URL(href, baseUrl).toString(); } catch { return null; }
  };
  const head = html.slice(0, 200_000);   // logos live in <head>; cap the scan
  const out: string[] = [];
  const push = (href: string | null | undefined) => {
    if (!href) return;
    const a = abs(href);
    if (a && !out.includes(a)) out.push(a);
  };

  const linkTags = head.match(/<link\b[^>]*>/gi) ?? [];
  const relOf = (tag: string) => (tag.match(/\brel=["']([^"']+)["']/i)?.[1] ?? "").toLowerCase();
  const hrefOf = (tag: string) => tag.match(/\bhref=["']([^"']+)["']/i)?.[1];
  const sizeOf = (tag: string) =>
    parseInt(tag.match(/\bsizes=["'](\d+)/i)?.[1] ?? "0", 10) || 0;

  // apple-touch-icon(-precomposed): usually the real square brand mark.
  for (const tag of linkTags) {
    if (relOf(tag).includes("apple-touch-icon")) push(hrefOf(tag));
  }
  // rel=icon / shortcut icon, largest declared size first.
  const iconLinks = linkTags
    .filter((tag) => /(^|\s)(shortcut\s+)?icon(\s|$)/.test(relOf(tag)))
    .sort((a, b) => sizeOf(b) - sizeOf(a));
  for (const tag of iconLinks) push(hrefOf(tag));

  // og:image / twitter:image: a marketing image (may be a banner), last resort.
  const metaTags = head.match(/<meta\b[^>]*>/gi) ?? [];
  for (const tag of metaTags) {
    const prop = (tag.match(/\b(?:property|name)=["']([^"']+)["']/i)?.[1] ?? "").toLowerCase();
    if (prop === "og:image" || prop === "twitter:image") {
      push(tag.match(/\bcontent=["']([^"']+)["']/i)?.[1]);
    }
  }
  return out;
}

// Decode arbitrary image bytes (PNG/JPEG/GIF) and re-encode a normalized PNG
// no larger than LOGO_PX on its longest edge, preserving aspect + alpha. Returns
// null when the bytes aren't a decodable raster (e.g. SVG/ICO) — caller falls
// through to the next source.
async function normalizePng(bytes: Uint8Array): Promise<Uint8Array | null> {
  try {
    const img = await Image.decode(bytes);
    const longest = Math.max(img.width, img.height);
    if (longest > LOGO_PX) {
      const scale = LOGO_PX / longest;
      img.resize(Math.max(1, Math.round(img.width * scale)),
                 Math.max(1, Math.round(img.height * scale)));
    }
    return await img.encode();   // PNG
  } catch {
    return null;
  }
}

// Ordered logo source URLs for a website. Brandfetch first when configured
// (purpose-built), then the site's own icons, then the favicon service.
async function candidateUrls(website: string): Promise<string[]> {
  const urls: string[] = [];
  const domain = domainOf(website);
  if (BRANDFETCH_CLIENT_ID && domain) {
    urls.push(`https://cdn.brandfetch.io/${domain}/w/${LOGO_PX}/h/${LOGO_PX}?c=${BRANDFETCH_CLIENT_ID}`);
  }
  const site = website.includes("://") ? website : `https://${website}`;
  const html = await fetchText(site);
  if (html) urls.push(...iconCandidates(html, site));
  if (domain) {
    // Google's favicon service always renders a PNG; last resort (can return a
    // generic globe for icon-less sites, which is why it's ordered last).
    urls.push(`https://www.google.com/s2/favicons?domain=${domain}&sz=128`);
  }
  return urls;
}

type Resolved = { bytes: Uint8Array; source: string };

async function resolveLogo(website: string): Promise<Resolved | null> {
  const urls = await candidateUrls(website);
  for (const url of urls) {
    const raw = await fetchBytes(url);
    if (!raw) continue;
    const png = await normalizePng(raw);
    if (!png) continue;
    const source = url.includes("brandfetch.io") ? "brandfetch"
      : url.includes("s2/favicons") ? "favicon"
      : "og_scrape";
    return { bytes: png, source };
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (APP_TOKEN && req.headers.get("x-app-token") !== APP_TOKEN) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!SUPA_URL || !SERVICE_KEY) return json({ error: "not configured" }, 500);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const rawItems = Array.isArray(payload.items) ? payload.items : [];
  // Dedup by place_id, keep first website seen, cap the batch.
  const items = new Map<string, string | null>();
  for (const it of rawItems) {
    const id = (it as { place_id?: unknown })?.place_id;
    const website = (it as { website?: unknown })?.website;
    if (typeof id !== "string" || !id) continue;
    if (!items.has(id)) items.set(id, typeof website === "string" && website ? website : null);
    if (items.size >= MAX_ITEMS) break;
  }
  if (items.size === 0) return json({ logos: {} });

  const admin = createClient(SUPA_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const ids = [...items.keys()];

  // 1. Load what's already resolved. A row with logo_checked_at set is settled
  //    (hit OR negative) and must not be re-resolved.
  const checked = new Set<string>();
  const out: Record<string, string> = {};
  const { data: rows } = await admin
    .from("business_enrichment")
    .select("place_id, logo_path, logo_checked_at")
    .in("place_id", ids);
  for (const r of rows ?? []) {
    if (r.logo_checked_at) {
      checked.add(r.place_id);
      if (r.logo_path) out[r.place_id] = publicUrl(r.logo_path);
    }
  }

  // 2. Resolve the misses that have a website (bounded concurrency).
  const toResolve = ids.filter((id) => !checked.has(id) && items.get(id));
  const nowIso = new Date().toISOString();

  await Promise.all(toResolve.map(async (id) => {
    const website = items.get(id)!;
    let path: string | null = null;
    let source = "none";
    try {
      const resolved = await resolveLogo(website);
      if (resolved) {
        path = `${id}.png`;
        const up = await admin.storage.from(BUCKET).upload(path, resolved.bytes, {
          contentType: "image/png",
          cacheControl: CACHE_CONTROL,
          upsert: true,
        });
        if (up.error) { path = null; }
        else { source = resolved.source; }
      }
    } catch (err) {
      console.error("logos: resolve failed", id, err);
    }
    // Write the outcome — including a negative (logo_source='none') so we never
    // re-resolve this business. upsert touches only these columns; other
    // enrichment fields on the row are preserved.
    await admin.from("business_enrichment").upsert({
      place_id: id,
      logo_path: path,
      logo_source: source,
      logo_checked_at: nowIso,
    }, { onConflict: "place_id" });
    if (path) out[id] = publicUrl(path);
  }));

  return json({ logos: out });
});
