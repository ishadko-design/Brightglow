// Supabase Edge Function: `business-photos`
//
// Free, zero-consent photo enrichment: given a business's own website (Google
// Places gives us `websiteUri`), find the photos it shows of its work and hand
// them back to the app's gallery. Unlike Google Places (10 max, no caching) or
// Foursquare/Yelp (paid, 24h cache), a business's own public site is free to
// read and its images are cacheable — so this is the highest-yield free source.
//
//   POST { place_id, website }
//        -> { photos: [{ url, w, h }], ok }
//
// FAN-IN so the app never over-calls: results are cached per place_id and reused
// by every later viewer, so the external website fetch happens once per business
// (until the TTL lapses), not once per gallery-open. The client only ever calls
// this function.
//
// Best-effort throughout: any failure returns `{ photos: [], ok:false }` and the
// gallery just falls back to the Places photos. Respects robots.txt, sends an
// identifying UA, times out fast, and only reads a couple of pages.
//
// Deploy:  supabase functions deploy business-photos
// Table:   supabase/migrations/*_business_website_photos.sql
//
// NOTE: unauthenticated (verify_jwt = false) like `search` / `verdicts` /
// `licenses`; the shared APP_TOKEN gate is enforced only when the secret is set.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { DOMParser, type Element } from "jsr:@b-fuze/deno-dom";

const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;
const APP_TOKEN = Deno.env.get("APP_TOKEN") ?? "";

const CACHE_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
const MAX_PHOTOS = 12;
const FETCH_TIMEOUT_MS = 6000;
const UA = "BrightglowBot/1.0 (+https://brightglow.co/bot; photo enrichment for the business's own listing)";
// Pages beyond the homepage that tend to hold the actual work photos.
const GALLERY_PATHS = ["/gallery", "/projects", "/portfolio", "/work", "/our-work", "/photos"];
// Filename/URL fragments that mark chrome rather than work photos.
const JUNK_RE = /(logo|icon|sprite|favicon|avatar|badge|placeholder|spinner|loader|pixel|1x1|banner-ad)/i;

interface Photo { url: string; w: number | null; h: number | null; }

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Normalize to an absolute http(s) origin/URL, or null. */
function normalizeUrl(raw: unknown): URL | null {
  if (typeof raw !== "string" || !raw.trim()) return null;
  let s = raw.trim();
  if (!/^https?:\/\//i.test(s)) s = "https://" + s;
  try {
    const u = new URL(s);
    return u.protocol === "http:" || u.protocol === "https:" ? u : null;
  } catch {
    return null;
  }
}

async function fetchText(url: string): Promise<string | null> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": UA, "Accept": "text/html,*/*" },
      redirect: "follow",
      signal: ctrl.signal,
    });
    if (!res.ok) return null;
    const type = res.headers.get("content-type") ?? "";
    if (!type.includes("html") && !type.includes("xml") && !type.includes("text")) return null;
    return await res.text();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** Minimal robots.txt honor: block only when a rule for us (or *) disallows "/". */
async function robotsAllows(origin: string): Promise<boolean> {
  const body = await fetchText(`${origin}/robots.txt`);
  if (!body) return true; // no robots.txt → allowed
  const lines = body.split(/\r?\n/).map((l) => l.replace(/#.*$/, "").trim());
  let appliesToUs = false;
  let disallowRoot = false;
  for (const line of lines) {
    const [rawKey, ...rest] = line.split(":");
    if (!rest.length) continue;
    const key = rawKey.trim().toLowerCase();
    const val = rest.join(":").trim();
    if (key === "user-agent") {
      appliesToUs = val === "*" || val.toLowerCase().includes("brightglow");
    } else if (key === "disallow" && appliesToUs && val === "/") {
      disallowRoot = true;
    }
  }
  return !disallowRoot;
}

function pickDimension(v: string | null): number | null {
  if (!v) return null;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
}

/** Extract candidate photo URLs from one HTML document. */
function extractPhotos(html: string, base: URL): Photo[] {
  const doc = new DOMParser().parseFromString(html, "text/html");
  if (!doc) return [];
  const out: Photo[] = [];
  const seen = new Set<string>();

  const add = (raw: string | null, w: number | null = null, h: number | null = null) => {
    if (!raw) return;
    let abs: string;
    try {
      abs = new URL(raw, base).toString();
    } catch {
      return;
    }
    if (!/^https?:\/\//i.test(abs)) return;
    if (abs.startsWith("data:")) return;
    if (/\.svg(\?|$)/i.test(abs)) return;
    if (JUNK_RE.test(abs)) return;
    if (seen.has(abs)) return;
    // If explicit dimensions say it's tiny, it's chrome, not a work photo.
    if ((w !== null && w < 200) || (h !== null && h < 200)) return;
    seen.add(abs);
    out.push({ url: abs, w, h });
  };

  // og:image / twitter:image — the site's chosen hero, usually a real photo.
  for (const sel of ['meta[property="og:image"]', 'meta[name="twitter:image"]']) {
    for (const m of Array.from(doc.querySelectorAll(sel)) as Element[]) {
      add(m.getAttribute("content"));
    }
  }
  // <img> content images.
  for (const img of Array.from(doc.querySelectorAll("img")) as Element[]) {
    const cls = `${img.getAttribute("class") ?? ""} ${img.getAttribute("id") ?? ""}`;
    if (JUNK_RE.test(cls)) continue;
    const src = img.getAttribute("src") || img.getAttribute("data-src") ||
      img.getAttribute("data-lazy-src");
    add(src, pickDimension(img.getAttribute("width")), pickDimension(img.getAttribute("height")));
  }
  return out;
}

/** Find same-origin gallery/portfolio links worth a second fetch. */
function galleryLinks(html: string, base: URL): string[] {
  const doc = new DOMParser().parseFromString(html, "text/html");
  if (!doc) return [];
  const out: string[] = [];
  const seen = new Set<string>();
  for (const a of Array.from(doc.querySelectorAll("a[href]")) as Element[]) {
    const href = a.getAttribute("href");
    if (!href) continue;
    let u: URL;
    try {
      u = new URL(href, base);
    } catch {
      continue;
    }
    if (u.origin !== base.origin) continue;
    const path = u.pathname.toLowerCase().replace(/\/$/, "");
    if (GALLERY_PATHS.some((g) => path === g || path.endsWith(g))) {
      const key = u.origin + u.pathname;
      if (!seen.has(key)) {
        seen.add(key);
        out.push(u.toString());
      }
    }
  }
  return out;
}

async function scrapeWebsite(website: URL): Promise<Photo[]> {
  const origin = website.origin;
  if (!(await robotsAllows(origin))) return [];

  const home = await fetchText(website.toString());
  if (!home) return [];

  const photos: Photo[] = extractPhotos(home, website);

  // Follow up to two gallery-ish pages for the actual work shots.
  const links = galleryLinks(home, website).slice(0, 2);
  for (const link of links) {
    if (photos.length >= MAX_PHOTOS) break;
    const page = await fetchText(link);
    if (!page) continue;
    const seen = new Set(photos.map((p) => p.url));
    for (const p of extractPhotos(page, new URL(link))) {
      if (!seen.has(p.url)) {
        seen.add(p.url);
        photos.push(p);
      }
    }
  }
  return photos.slice(0, MAX_PHOTOS);
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

  const placeId = typeof payload.place_id === "string" ? payload.place_id.trim() : "";
  const website = normalizeUrl(payload.website);
  if (!placeId) return json({ error: "place_id is required" }, 400);
  // No website to read → nothing to do, but answer cleanly so the client caches
  // the empty result for the session rather than retrying.
  if (!website) return json({ photos: [], ok: false });

  // Cache hit within the TTL → serve it, zero external fetch.
  const { data: cached } = await db.from("business_website_photos")
    .select("photos, ok, fetched_at").eq("place_id", placeId).maybeSingle();
  if (cached && cached.fetched_at &&
      Date.now() - new Date(cached.fetched_at).getTime() < CACHE_TTL_MS) {
    return json({ photos: cached.photos ?? [], ok: cached.ok ?? false });
  }

  // Miss (or stale) → scrape once, store, share with every later viewer.
  const photos = await scrapeWebsite(website);
  await db.from("business_website_photos").upsert({
    place_id: placeId,
    website: website.toString(),
    photos,
    ok: photos.length > 0,
    fetched_at: new Date().toISOString(),
  });
  return json({ photos, ok: photos.length > 0 });
});
