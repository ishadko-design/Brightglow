#!/usr/bin/env -S deno run --allow-net --allow-env
//
// Imports the CSLB license master into `public.cslb_licenses`.
//
//   SUPABASE_URL=https://<ref>.supabase.co \
//   SUPABASE_SERVICE_ROLE_KEY=<service key> \
//   deno run --allow-net --allow-env scripts/import-cslb.ts
//
// Run it monthly — CSLB regenerates the export continuously, and a license that
// lapses or gets suspended must stop showing a "Licensed" badge. `--dry-run`
// parses and reports without writing.
//
// Why phone-keyed: 99.9% of the 243k rows carry a 10-digit business phone, and
// Google Places returns `nationalPhoneNumber` for the same business, so an exact
// normalized-digit match beats any fuzzy name/address matching. See the table's
// migration for the full rationale.
//
// The CSV is ~77MB, so it's streamed and upserted in chunks rather than buffered.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CSV_URL =
  "https://www.cslb.ca.gov/OnlineServices/DataPortal/DownLoadFile.ashx?fName=MasterLicenseData&type=C";

// Only this status means "in good standing". Everything else in the export is
// some flavour of suspension (Contr Bond Susp, Work Comp Susp, Judgement Susp …).
const ACTIVE_STATUS = "CLEAR";
const CHUNK = 1000;

const DRY_RUN = Deno.args.includes("--dry-run");
const SUPA_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

if (!DRY_RUN && (!SUPA_URL || !SERVICE_KEY)) {
  console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (or pass --dry-run).");
  Deno.exit(1);
}
const db = DRY_RUN ? null : createClient(SUPA_URL, SERVICE_KEY);

/** Exactly 10 digits, or null. Strips "(415) 652 2093" → "4156522093". */
function normalizePhone(raw: string): string | null {
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 10) return digits;
  // Occasional leading country code.
  if (digits.length === 11 && digits.startsWith("1")) return digits.slice(1);
  return null;
}

/** CSLB writes dates as MM/DD/YYYY; Postgres wants YYYY-MM-DD. Blank → null. */
function isoDate(raw: string): string | null {
  const m = raw.trim().match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  return m ? `${m[3]}-${m[1]}-${m[2]}` : null;
}

/** Minimal RFC-4180 line splitter: handles quoted fields containing commas. */
function splitCSVLine(line: string): string[] {
  const out: string[] = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQuotes) {
      if (c === '"') {
        if (line[i + 1] === '"') { field += '"'; i++; } else { inQuotes = false; }
      } else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ",") { out.push(field); field = ""; }
    else field += c;
  }
  out.push(field);
  return out;
}

type Row = {
  license_no: string;
  business_name: string;
  phone: string | null;
  city: string | null;
  zip: string | null;
  primary_status: string | null;
  classifications: string | null;
  expiration_date: string | null;
  is_active: boolean;
};

async function flush(rows: Row[]): Promise<void> {
  if (rows.length === 0 || !db) return;
  const { error } = await db.from("cslb_licenses").upsert(rows, { onConflict: "license_no" });
  if (error) throw new Error(`upsert failed: ${error.message}`);
}

console.log(`Downloading ${CSV_URL}`);
const resp = await fetch(CSV_URL);
if (!resp.ok || !resp.body) {
  console.error(`Download failed: HTTP ${resp.status}`);
  Deno.exit(1);
}

const today = new Date().toISOString().slice(0, 10);
let header: string[] | null = null;
let buffer = "";
let batch: Row[] = [];
let total = 0, active = 0, withPhone = 0, skipped = 0;

const reader = resp.body.pipeThrough(new TextDecoderStream("utf-8")).getReader();

/** Parse whatever complete lines `buffer` holds, leaving any partial tail. */
async function drain(final = false): Promise<void> {
  const lines = buffer.split(/\r?\n/);
  buffer = final ? "" : (lines.pop() ?? "");   // last piece may be a partial line

  for (const line of lines) {
    if (!line.trim()) continue;
    const cols = splitCSVLine(line);

    if (!header) {
      header = cols.map((c) => c.trim());
      continue;
    }
    const get = (name: string) => {
      const i = header!.indexOf(name);
      return i >= 0 ? (cols[i] ?? "").trim() : "";
    };

    const licenseNo = get("LicenseNo");
    const name = get("BusinessName");
    if (!licenseNo || !name) { skipped++; continue; }

    const expiry = isoDate(get("ExpirationDate"));
    const status = get("PrimaryStatus");
    const phone = normalizePhone(get("BusinessPhone"));

    // "Licensed" must mean: not suspended, and not lapsed. The export contains
    // both, so both are checked here rather than trusted from membership.
    const isActive = status === ACTIVE_STATUS && expiry !== null && expiry >= today;

    total++;
    if (isActive) active++;
    if (phone) withPhone++;

    batch.push({
      license_no: licenseNo,
      business_name: name,
      phone,
      city: get("City") || null,
      zip: get("ZIPCode") || null,
      primary_status: status || null,
      // Header is literally "Classifications(s)" in CSLB's export.
      classifications: get("Classifications(s)") || null,
      expiration_date: expiry,
      is_active: isActive,
    });

    if (batch.length >= CHUNK) {
      await flush(batch);
      batch = [];
      if (total % 50_000 === 0) console.log(`  …${total.toLocaleString()} rows`);
    }
  }
}

while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  buffer += value;
  await drain();
}
await drain(true);
await flush(batch);

console.log(
  `\nParsed ${total.toLocaleString()} licenses ` +
    `(${active.toLocaleString()} active, ${withPhone.toLocaleString()} with a phone, ${skipped} skipped).`,
);
console.log(DRY_RUN ? "Dry run — nothing written." : "Imported into cslb_licenses.");
