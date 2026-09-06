// brightglow.co — static site + a thin reverse proxy to LeadBridge.
//
// Everything under site/ is served straight from the ASSETS binding. Two paths
// are proxied to the LeadBridge backend (a separate service on Railway) so they
// come from our own origin:
//
//   /api/*  — the business portal POSTs chat replies to
//             /api/threads/:publicId/messages. LeadBridge sends no CORS headers,
//             so a cross-origin POST from brightglow.co would be blocked. Same
//             origin => no preflight, no CORS, and no change needed in the
//             separate LeadBridge repo.
//   /chat   — the standalone web chat page lives in LeadBridge and was only
//             reachable at its Railway URL. Serving it here keeps links
//             on-brand and matches the /chat Universal Link the iOS app already
//             recognises (ChatRouter.swift), so one URL works on phone and desktop.
//
// This proxy holds NO authority of its own: it forwards the caller's
// Authorization header untouched and LeadBridge verifies that Supabase JWT
// itself. It cannot authenticate anyone; it only relays what the browser sent.

const LEADBRIDGE = "https://leadbridge-production-4065.up.railway.app";

// Private analytics dashboard (site/analytics.html). The page and its data are
// gated at the edge by HTTP Basic Auth here — nothing sensitive lives in the
// page, and the Supabase admin secret is injected server-side on /analytics/data
// so the browser never holds it. Secrets (set with `wrangler secret put`):
//   DASH_PASSWORD           — the dashboard login password
//   ANALYTICS_ADMIN_SECRET  — the Supabase ADMIN_SECRET the analytics fn checks
const ANALYTICS_FN = "https://qxoseyrlbvblpwqzwvvk.supabase.co/functions/v1/analytics";

function isProxied(pathname) {
  return pathname.startsWith("/api/") || pathname === "/chat" || pathname.startsWith("/chat/");
}

// Any /analytics path (the HTML and its data endpoint) is behind the login.
function isAnalytics(pathname) {
  return pathname === "/analytics" || pathname === "/analytics.html" ||
         pathname === "/analytics/data";
}

// Basic Auth: username is ignored, only the password must match DASH_PASSWORD.
function authOK(request, env) {
  const h = request.headers.get("Authorization") || "";
  if (!h.startsWith("Basic ")) return false;
  let decoded = "";
  try { decoded = atob(h.slice(6)); } catch { return false; }
  const pass = decoded.slice(decoded.indexOf(":") + 1);
  return !!env.DASH_PASSWORD && pass === env.DASH_PASSWORD;
}

function needsLogin() {
  return new Response("Authentication required", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="Brightglow Analytics", charset="UTF-8"' },
  });
}

// Forward the dashboard's request to the analytics Edge Function, adding the
// admin secret. Returns the function's JSON verbatim.
async function analyticsData(request, env) {
  const body = request.method === "POST" ? await request.text() : '{"days":30}';
  const resp = await fetch(ANALYTICS_FN, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-admin-secret": env.ANALYTICS_ADMIN_SECRET || "" },
    body,
  });
  return new Response(resp.body, {
    status: resp.status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

async function proxy(request, url) {
  const target = LEADBRIDGE + url.pathname + url.search;

  const headers = new Headers(request.headers);
  headers.set("Host", new URL(LEADBRIDGE).host);
  // Preserve the real client IP for the origin's logs/rate-limiting.
  const ip = request.headers.get("cf-connecting-ip");
  if (ip) headers.set("X-Forwarded-For", ip);

  const resp = await fetch(target, {
    method: request.method,
    headers,
    body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
    redirect: "manual",
  });

  // Drop headers that describe the ORIGIN's transfer encoding — Cloudflare
  // re-applies its own, and passing these through corrupts the response.
  const out = new Headers(resp.headers);
  out.delete("content-encoding");
  out.delete("content-length");
  out.delete("transfer-encoding");

  return new Response(resp.body, { status: resp.status, headers: out });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (isProxied(url.pathname)) return proxy(request, url);

    // Gate the analytics dashboard: no valid login → prompt. Then either return
    // the proxied data, or fall through to serve the (auth'd) HTML page.
    if (isAnalytics(url.pathname)) {
      if (!authOK(request, env)) return needsLogin();
      if (url.pathname === "/analytics/data") return analyticsData(request, env);
    }

    const resp = await env.ASSETS.fetch(request);

    // The zone edge-caches responses, which pinned stale HTML/JS/CSS across
    // deploys — a fix would ship but visitors kept the old file for hours.
    // Tell Cloudflare's edge not to cache the markup/code (this header is
    // honoured by the edge and stripped before the browser), so a deploy is
    // live immediately. Images/fonts keep their default caching.
    if (url.pathname.endsWith("/") || /\.(html|js|css)$/.test(url.pathname)) {
      const out = new Response(resp.body, resp);
      out.headers.set("Cloudflare-CDN-Cache-Control", "no-store");
      return out;
    }
    return resp;
  },
};
