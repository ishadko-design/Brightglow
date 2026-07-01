// Supabase Edge Function: `search`
//
// Proxies Google Places Text Search so the API key stays server-side (never in
// the app binary). The app POSTs { textQuery, latitude, longitude, pageSize,
// pageToken } and gets back Google's raw response, which the iOS client decodes
// as-is.
//
// Deploy:   supabase functions deploy search
// Secret:   supabase secrets set GOOGLE_PLACES_KEY=<server-only key>
//
// NOTE (Phase 1): this function is currently unauthenticated (verify_jwt = false
// in config.toml) and is protected only by the Google per-day quota cap. Adding
// real auth is a Phase 4 hardening step. See docs/cheap-api-plan.md.

const GOOGLE_KEY = Deno.env.get("GOOGLE_PLACES_KEY") ?? "";
const SEARCH_URL = "https://places.googleapis.com/v1/places:searchText";
const FIELD_MASK = [
  "places.id", "places.displayName", "places.rating", "places.userRatingCount",
  "places.formattedAddress", "places.nationalPhoneNumber", "places.photos",
  "places.businessStatus", "places.reviews", "places.location", "nextPageToken",
].join(",");
const RADIUS_M = 40000;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!GOOGLE_KEY) return json({ error: "server key not configured" }, 500);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json body" }, 400);
  }

  const textQuery = payload.textQuery;
  const latitude = payload.latitude;
  const longitude = payload.longitude;
  const pageToken = payload.pageToken;
  const pageSize = typeof payload.pageSize === "number" ? payload.pageSize : 20;

  if (typeof textQuery !== "string" || textQuery.length === 0 ||
      typeof latitude !== "number" || typeof longitude !== "number") {
    return json({ error: "missing textQuery / latitude / longitude" }, 400);
  }

  const body: Record<string, unknown> = {
    textQuery,
    maxResultCount: pageSize,
    locationBias: { circle: { center: { latitude, longitude }, radius: RADIUS_M } },
  };
  if (typeof pageToken === "string" && pageToken.length > 0) body.pageToken = pageToken;

  const resp = await fetch(SEARCH_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": GOOGLE_KEY,
      "X-Goog-FieldMask": FIELD_MASK,
    },
    body: JSON.stringify(body),
  });

  // Pass Google's response straight through — the iOS app decodes it directly.
  const text = await resp.text();
  return new Response(text, {
    status: resp.status,
    headers: { "Content-Type": "application/json" },
  });
});
