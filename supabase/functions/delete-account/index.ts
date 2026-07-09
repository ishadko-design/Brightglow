// Supabase Edge Function: `delete-account`
//
// Apple App Store Guideline 5.1.1(v) requires apps that support account
// creation to let users delete their account from within the app. This purges
// the caller's personal data (leads, message bodies, photos) and then deletes
// their auth user.
//
//   POST (no body) with the signed-in user's access token as Bearer
//        -> { ok: true, leads_deleted, storage_deleted }
//
// Auth: `verify_jwt = true` (config.toml) rejects unauthenticated calls before
// this runs. We ADDITIONALLY call auth.getUser() to confirm a real USER — the
// project's anon key is itself a valid JWT but resolves to no user, so this is
// what stops an anon-key caller from deleting anything. All deletion runs with
// the service role (bypasses RLS).
//
// Deploy:  supabase functions deploy delete-account

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
// Same bucket LeadBridge stores stripped photos in (leadbridge/src/lib/storage.js).
const BUCKET = Deno.env.get("LEADBRIDGE_STORAGE_BUCKET") ?? "leadbridge-photos";

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!SUPA_URL || !SERVICE_KEY) return json({ error: "not configured" }, 500);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "missing bearer token" }, 401);

  const admin = createClient(SUPA_URL, SERVICE_KEY, { auth: { persistSession: false } });

  // Confirm a real user is behind the token (anon key -> no user -> reject).
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  const user = userData?.user;
  if (userErr || !user) return json({ error: "unauthorized" }, 401);

  const uid = user.id;
  const email = (user.email ?? "").trim().toLowerCase();

  try {
    // 1. Collect the caller's leads by owner id AND by email — older leads
    //    predate the user_id wiring and are keyed only by user_email. Two
    //    separate .eq() queries (not a string-built .or()) so a stray char in
    //    the email can't become a filter-injection.
    const leadIds = new Set<string>();
    const byId = await admin.from("leads").select("id").eq("user_id", uid);
    if (byId.error) throw byId.error;
    byId.data?.forEach((l: { id: string }) => leadIds.add(l.id));
    if (email) {
      const byEmail = await admin.from("leads").select("id").eq("user_email", email);
      if (byEmail.error) throw byEmail.error;
      byEmail.data?.forEach((l: { id: string }) => leadIds.add(l.id));
    }
    const ids = [...leadIds];

    let storageDeleted = 0;
    if (ids.length > 0) {
      // 2. Delete storage objects (named by attachment id) BEFORE the rows —
      //    the row is what carries the object id.
      const atts = await admin.from("attachments").select("id").in("lead_id", ids);
      if (atts.error) throw atts.error;
      const objectIds = (atts.data ?? []).map((a: { id: string }) => a.id);
      if (objectIds.length > 0) {
        const { error: rmErr } = await admin.storage.from(BUCKET).remove(objectIds);
        if (rmErr) throw rmErr;
        storageDeleted = objectIds.length;
      }
      // 3. Delete the leads; messages + attachments cascade via FK.
      const del = await admin.from("leads").delete().in("id", ids);
      if (del.error) throw del.error;
    }

    // 4. Delete the auth user LAST. Data is already gone, so if this step fails
    //    the user can retry: the next call finds no leads and just removes them.
    const { error: authDelErr } = await admin.auth.admin.deleteUser(uid);
    if (authDelErr) throw authDelErr;

    return json({ ok: true, leads_deleted: ids.length, storage_deleted: storageDeleted });
  } catch (err) {
    return json({ error: "deletion failed", detail: String((err as Error)?.message ?? err) }, 500);
  }
});
