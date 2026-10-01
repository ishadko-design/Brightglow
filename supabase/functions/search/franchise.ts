// Collapse franchise siblings: several locations of one brand (Miracle Method
// SF North / Alameda-Contra Costa / San Jose / Sonoma-Marin) share a website
// domain and corporate photos, so the list read as the same business twice
// (reported 2026-09-30). Keep the location NEAREST the user per domain.
// Hosting/social domains are shared by unrelated businesses — never grouped.

const SHARED_HOSTS = [
  "facebook.com", "instagram.com", "yelp.com", "google.com", "business.site",
  "sites.google.com", "linktr.ee", "wixsite.com", "square.site", "godaddysites.com",
  "angi.com", "homeadvisor.com", "thumbtack.com", "nextdoor.com", "houzz.com",
  "bbb.org", "linkedin.com", "twitter.com", "x.com", "tiktok.com", "youtube.com",
  "weebly.com", "wordpress.com", "squarespace.com", "carrd.co", "porch.com",
];

/** Registrable-ish domain of a website ("https://www.miraclemethod.com/sf?x" ->
 *  "miraclemethod.com"), or "" when there's none / it's a shared host. */
export function brandDomain(website: unknown): string {
  if (typeof website !== "string" || !website) return "";
  let host = "";
  try { host = new URL(website).hostname.toLowerCase(); } catch { return ""; }
  host = host.replace(/^www\d*\./, "");
  const parts = host.split(".");
  // Keep the last two labels (three for e.g. co.uk-style suffixes).
  const keep = parts.length >= 3 && parts[parts.length - 2].length <= 3 ? 3 : 2;
  const domain = parts.slice(-keep).join(".");
  if (SHARED_HOSTS.some((h) => domain === h || host.endsWith(`.${h}`) || host === h)) return "";
  return domain;
}

function km(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const r = (d: number) => (d * Math.PI) / 180;
  const dLat = r(bLat - aLat), dLng = r(bLng - aLng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(r(aLat)) * Math.cos(r(bLat)) * Math.sin(dLng / 2) ** 2;
  return 12742 * Math.asin(Math.sqrt(h));
}

/** Returns the places with franchise siblings collapsed to the nearest one,
 *  preserving the original order of the survivors. */
export function collapseFranchises(
  places: Array<Record<string, unknown>>, lat: number, lng: number,
): Array<Record<string, unknown>> {
  const best = new Map<string, { idx: number; d: number }>();
  places.forEach((p, idx) => {
    const dom = brandDomain(p.websiteUri);
    if (!dom) return;
    const loc = p.location as { latitude?: number; longitude?: number } | undefined;
    const d = loc?.latitude != null && loc?.longitude != null
      ? km(lat, lng, loc.latitude, loc.longitude) : Number.POSITIVE_INFINITY;
    const cur = best.get(dom);
    if (!cur || d < cur.d) best.set(dom, { idx, d });
  });
  return places.filter((p, idx) => {
    const dom = brandDomain(p.websiteUri);
    return !dom || best.get(dom)?.idx === idx;
  });
}
