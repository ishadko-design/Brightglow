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

function isProxied(pathname) {
  return pathname.startsWith("/api/") || pathname === "/chat" || pathname.startsWith("/chat/");
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
    return env.ASSETS.fetch(request);
  },
};
