// Supabase Edge Function: `analytics`
//
// Private funnel dashboard backend. Reads the append-only `analytics_events`
// table with the service role (the table has no client read path) and returns
// aggregates. Gated by ADMIN_SECRET — only the holder of that secret can read.
//
//   POST { days?: number }   header  x-admin-secret: <secret>
//        -> { range, totals, funnel, send, calls, daily }
//
// The dashboard (site/analytics.html) is a static page that holds no data; it
// asks you for the secret, calls this, and renders the numbers.
//
// Deploy:
//   supabase functions deploy analytics --no-verify-jwt
//   supabase secrets set ADMIN_SECRET='<a long random string only you know>'
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ADMIN_SECRET = Deno.env.get("ADMIN_SECRET") ?? "";
const db = SUPA_URL && SERVICE_KEY ? createClient(SUPA_URL, SERVICE_KEY) : null;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-admin-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

type Row = { created_at: string; event: string; props: Record<string, unknown> };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  // Constant-ish secret gate. Fail closed: if no secret is configured, deny.
  if (!ADMIN_SECRET || req.headers.get("x-admin-secret") !== ADMIN_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!db) return json({ error: "db not configured" }, 500);

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body ok */ }

  // Admin maintenance: wipe the table (used to clear the owner's test events
  // before real data flows). Gated by the same admin secret as everything else.
  if (body.op === "reset") {
    const { error } = await db.from("analytics_events").delete().gte("created_at", "1970-01-01");
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, reset: true });
  }

  // Exclude / un-exclude a device from every number (retroactive — filtering
  // happens at read time below). `device_id` is the app's vendor id, stamped on
  // every event's props by AnalyticsService.
  if (body.op === "exclude") {
    const id = String(body.device_id ?? "").trim();
    if (!id) return json({ error: "device_id required" }, 400);
    const { error } = await db.from("analytics_excluded_devices")
      .upsert({ device_id: id, note: String(body.note ?? "") || null });
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, excluded: id });
  }
  if (body.op === "include") {
    const id = String(body.device_id ?? "").trim();
    if (!id) return json({ error: "device_id required" }, 400);
    const { error } = await db.from("analytics_excluded_devices").delete().eq("device_id", id);
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, included: id });
  }

  const days = Math.min(Math.max(Number(body.days) || 30, 1), 365);
  const since = new Date(Date.now() - days * 86_400_000).toISOString();

  // Excluded devices: their events are dropped from every number below. This is
  // the retroactive exclusion that replaces the old per-device opt-out flag.
  const excluded = new Set<string>();
  {
    const { data, error } = await db.from("analytics_excluded_devices").select("device_id");
    if (error) return json({ error: error.message }, 500);
    for (const r of (data ?? []) as { device_id: string }[]) excluded.add(r.device_id);
  }

  // Page through all events in the window (volume is tiny at this stage).
  // Per-device counts are tallied BEFORE the exclusion filter so the dashboard
  // can show every device (with an "excluded" flag) and let you pick which to drop.
  const rows: Row[] = [];
  const deviceCounts: Record<string, number> = {};
  const PAGE = 1000;
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await db
      .from("analytics_events")
      .select("created_at, event, props")
      .gte("created_at", since)
      .order("created_at", { ascending: true })
      .range(from, from + PAGE - 1);
    if (error) return json({ error: error.message }, 500);
    for (const r of (data as Row[])) {
      const did = String(r.props?.device_id ?? "unknown");
      deviceCounts[did] = (deviceCounts[did] ?? 0) + 1;
      if (!excluded.has(did)) rows.push(r);   // excluded devices never reach the aggregates
    }
    if (!data || data.length < PAGE) break;
  }

  // Device breakdown for the dashboard's exclude UI: id, event count, excluded?
  const devices = Object.entries(deviceCounts)
    .map(([device_id, events]) => ({ device_id, events, excluded: excluded.has(device_id) }))
    .sort((a, b) => b.events - a.events);

  // ── aggregate ──────────────────────────────────────────────────────────────
  const totals: Record<string, number> = {};
  const daily: Record<string, Record<string, number>> = {};
  const send = { sent: 0, cancelled: 0, failed: 0, text: 0, email: 0 };
  const calls = { list: 0, gallery: 0 };
  const placeSends: Record<string, number> = {};
  const placeImpressions: Record<string, number> = {};   // per-business impressions
  const placeOpens: Record<string, number> = {};          // per-business link opens
  const senderSends: Record<string, number> = {};         // per-customer-device sends
  const senderOpens: Record<string, number> = {};         // per-customer-device opens
  let impressionsTotal = 0;

  for (const r of rows) {
    totals[r.event] = (totals[r.event] ?? 0) + 1;

    const day = r.created_at.slice(0, 10);
    (daily[day] ??= {});
    daily[day][r.event] = (daily[day][r.event] ?? 0) + 1;

    // Per-business impressions come from two surfaces: the gallery fires one
    // `impression` per business surfaced; the list folds the ids it showed into
    // `results_shown.place_ids`. Tally both into placeImpressions.
    if (r.event === "impression") {
      const pid = String(r.props?.place_id ?? "");
      if (pid) { placeImpressions[pid] = (placeImpressions[pid] ?? 0) + 1; impressionsTotal++; }
    }
    if (r.event === "results_shown" && Array.isArray(r.props?.place_ids)) {
      for (const raw of r.props.place_ids as unknown[]) {
        const pid = String(raw ?? "");
        if (pid) { placeImpressions[pid] = (placeImpressions[pid] ?? 0) + 1; impressionsTotal++; }
      }
    }

    if (r.event === "send_result") {
      const outcome = String(r.props?.outcome ?? "");
      if (outcome in send) (send as Record<string, number>)[outcome]++;
      const channel = String(r.props?.channel ?? "");
      if (channel === "text" || channel === "email") send[channel]++;
      if (outcome === "sent") {
        const pid = String(r.props?.place_id ?? "");
        if (pid) placeSends[pid] = (placeSends[pid] ?? 0) + 1;
        const did = String(r.props?.device_id ?? "");
        if (did) senderSends[did] = (senderSends[did] ?? 0) + 1;
      }
    }
    // Link opens are stamped server-side by LeadBridge with the lead's place_id
    // and the sending customer's device id (sender_device_id is null for leads
    // created by older app versions).
    if (r.event === "link_opened") {
      const pid = String(r.props?.place_id ?? "");
      if (pid) placeOpens[pid] = (placeOpens[pid] ?? 0) + 1;
      const sdid = String(r.props?.sender_device_id ?? "");
      if (sdid) senderOpens[sdid] = (senderOpens[sdid] ?? 0) + 1;
    }
    if (r.event === "call_tapped") {
      const surface = String(r.props?.surface ?? "");
      if (surface === "list" || surface === "gallery") calls[surface]++;
    }
  }

  // The funnel, in order. Each stage is a distinct event count. app_open is the
  // new top of funnel (how many launches lead into a results view).
  const funnel = [
    { stage: "App opens", event: "app_open", count: totals.app_open ?? 0 },
    { stage: "Results shown", event: "results_shown", count: totals.results_shown ?? 0 },
    { stage: "Contractor viewed", event: "contractor_viewed", count: totals.contractor_viewed ?? 0 },
    { stage: "Quote opened", event: "quote_opened", count: totals.quote_opened ?? 0 },
    { stage: "Send tapped", event: "send_tapped", count: totals.send_tapped ?? 0 },
    { stage: "Sent (delivered)", event: "send_result:sent", count: send.sent },
  ];

  // Business names for the per-business table: leads carry the matched
  // business_name keyed by place_id (service role bypasses RLS).
  const placeNames: Record<string, string> = {};
  {
    const { data, error } = await db.from("leads").select("place_id, business_name").not("place_id", "is", null);
    if (!error) for (const r of (data ?? []) as { place_id: string; business_name: string | null }[]) {
      if (r.place_id && r.business_name && !placeNames[r.place_id]) placeNames[r.place_id] = r.business_name;
    }
  }

  // Top businesses: merge impressions + sends + opens so each row shows
  // reach → sent → opened.
  const placeIds = new Set([...Object.keys(placeImpressions), ...Object.keys(placeSends), ...Object.keys(placeOpens)]);
  const topPlaces = [...placeIds]
    .map((place_id) => ({
      place_id,
      name: placeNames[place_id] ?? null,
      impressions: placeImpressions[place_id] ?? 0,
      sends: placeSends[place_id] ?? 0,
      opens: placeOpens[place_id] ?? 0,
    }))
    .sort((a, b) => b.sends - a.sends || b.impressions - a.impressions || b.opens - a.opens)
    .slice(0, 15);

  // Per-customer-device sent → opened. Devices that only appear on one side
  // still show (the other side reads 0) so the ratio is never silently dropped.
  const senderIds = new Set([...Object.keys(senderSends), ...Object.keys(senderOpens)]);
  const topSenders = [...senderIds]
    .map((device_id) => ({
      device_id,
      sends: senderSends[device_id] ?? 0,
      opens: senderOpens[device_id] ?? 0,
    }))
    .sort((a, b) => b.sends - a.sends || b.opens - a.opens)
    .slice(0, 15);

  return json({
    range: { days, since, events: rows.length },
    totals,
    funnel,
    send,
    calls: { ...calls, total: calls.list + calls.gallery },
    impressions: { total: impressionsTotal, businesses: Object.keys(placeImpressions).length },
    topPlaces,
    topSenders,
    devices,
    daily,
  });
});
