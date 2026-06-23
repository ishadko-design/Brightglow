#!/usr/bin/env python3
"""
Seed script: fetches real contractor data from Google Places API
and writes FIXR/Models/MockData.swift
"""

import requests, json, time, re, sys, os
from datetime import datetime

API_KEY = os.environ.get("PLACES_API_KEY", "")
if not API_KEY:
    sys.exit("Set PLACES_API_KEY env var, e.g.  PLACES_API_KEY=xxx python3 scripts/seed_contractors.py")
CITY    = "San Francisco"
MAX_PER_CATEGORY = 10
MAX_PHOTOS       = 4

CATEGORIES = [
    ("plumbing",      "Plumbing",         "plumber contractor San Francisco CA"),
    ("electrical",    "Electrical",       "electrician contractor San Francisco CA"),
    ("hvac",          "HVAC",             "HVAC heating cooling contractor San Francisco CA"),
    ("painting",      "Painting",         "painting contractor San Francisco CA"),
    ("carpentry",     "Carpentry",        "carpenter contractor San Francisco CA"),
    ("roofing",       "Roofing",          "roofing contractor San Francisco CA"),
    ("flooring",      "Flooring",         "flooring contractor San Francisco CA"),
    ("windowsDoors",  "Windows & Doors",  "window door installation contractor San Francisco CA"),
]

# Realistic price tiers per category
PRICE_TIERS = {
    "plumbing":     [("Minor fix", 100, 250), ("Mid repair", 400, 900), ("Full replacement", 1000, 3000)],
    "electrical":   [("Outlet / fixture", 80, 200), ("Panel work", 400, 1000), ("Full rewire", 3000, 8000)],
    "hvac":         [("Tune-up", 100, 250), ("Repair", 300, 800), ("Full install", 3000, 7000)],
    "painting":     [("Single room", 200, 600), ("Full interior", 1500, 4000), ("Exterior", 3000, 9000)],
    "carpentry":    [("Small repair", 150, 400), ("Custom build", 800, 3500), ("Full remodel", 5000, 15000)],
    "roofing":      [("Patch / repair", 300, 800), ("Partial replace", 3000, 7000), ("Full roof", 8000, 20000)],
    "flooring":     [("Single room", 500, 1500), ("Whole floor", 2000, 6000), ("Full home", 8000, 20000)],
    "windowsDoors": [("Single unit", 300, 800), ("Multiple units", 1500, 4000), ("Full install", 5000, 12000)],
}

RESPONSE_TIMES = ["fast", "normal", "slow"]

# ── Helpers ──────────────────────────────────────────────────────────────────

def search_places(query):
    url = "https://places.googleapis.com/v1/places:searchText"
    headers = {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": API_KEY,
        "X-Goog-FieldMask": (
            "places.id,places.displayName,places.rating,"
            "places.userRatingCount,places.formattedAddress,"
            "places.nationalPhoneNumber,places.photos,"
            "places.businessStatus,places.regularOpeningHours"
        ),
    }
    body = {"textQuery": query, "maxResultCount": MAX_PER_CATEGORY, "languageCode": "en"}
    r = requests.post(url, headers=headers, json=body, timeout=15)
    if r.status_code != 200:
        print(f"  ⚠ Search error {r.status_code}: {r.text[:200]}")
        return []
    return r.json().get("places", [])

def get_photo_url(photo_name):
    url = f"https://places.googleapis.com/v1/{photo_name}/media"
    params = {"maxWidthPx": 800, "skipHttpRedirect": "true", "key": API_KEY}
    r = requests.get(url, params=params, timeout=10)
    if r.status_code == 200:
        return r.json().get("photoUri")
    return None

def extract_city(address):
    # "123 Main St, San Francisco, CA 94102, USA" → "San Francisco"
    parts = [p.strip() for p in address.split(",")]
    for p in parts:
        if CITY.lower() in p.lower():
            return CITY
    return CITY

def swift_string(s):
    if s is None:
        return "nil"
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'

def swift_optional_string(s):
    if not s:
        return "nil"
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'

# ── Main ─────────────────────────────────────────────────────────────────────

contractors = []
contractor_id = 1

for cat_key, cat_label, query in CATEGORIES:
    print(f"\n🔍 {cat_label}: {query}")
    places = search_places(query)

    if not places:
        print("  No results.")
        continue

    for i, place in enumerate(places):
        name      = place.get("displayName", {}).get("text", "Unknown")
        rating    = place.get("rating", 4.0)
        reviews   = place.get("userRatingCount", 0)
        phone     = place.get("nationalPhoneNumber")
        address   = place.get("formattedAddress", "")
        status    = place.get("businessStatus", "OPERATIONAL")
        verified  = status == "OPERATIONAL"

        print(f"  [{i+1}] {name} ★{rating} ({reviews} reviews)")

        # Fetch photo URLs (up to MAX_PHOTOS)
        photo_refs = place.get("photos", [])[:MAX_PHOTOS]
        photo_urls = []
        for ref in photo_refs:
            photo_name = ref.get("name", "")
            if photo_name:
                url = get_photo_url(photo_name)
                if url:
                    photo_urls.append(url)
                    print(f"    📸 photo ok")
                time.sleep(0.1)   # be polite to the API

        # Skip contractors with no photos — every card must have an image
        if not photo_urls:
            print("    ⏭  skipped (no photos)")
            continue

        # Assign response time round-robin
        rt = RESPONSE_TIMES[contractor_id % 3]

        contractors.append({
            "id":           str(contractor_id),
            "name":         name,
            "category":     cat_key,
            "city":         extract_city(address),
            "rating":       round(rating, 1),
            "reviewCount":  reviews,
            "responseTime": rt,
            "yearsActive":  5 + (contractor_id % 15),
            "photos":       photo_urls,
            "priceTiers":   PRICE_TIERS[cat_key],
            "phone":        phone,
            "isVerified":   verified,
        })
        contractor_id += 1
        time.sleep(0.15)

print(f"\n✅ Fetched {len(contractors)} contractors across {len(CATEGORIES)} categories")

# ── Write MockData.swift ─────────────────────────────────────────────────────

lines = [
    "// Auto-generated by scripts/seed_contractors.py",
    f"// {datetime.now().strftime('%Y-%m-%d')} — Google Places API",
    "import Foundation",
    "",
    "let mockContractors: [Contractor] = [",
]

for c in contractors:
    photos_swift = ", ".join(f'"{u}"' for u in c["photos"])
    tiers_swift = ", ".join(
        f'PriceTier(label: "{l}", min: {mn}, max: {mx})'
        for l, mn, mx in c["priceTiers"]
    )
    lines += [
        "    Contractor(",
        f'        id: "{c["id"]}", name: {swift_string(c["name"])},',
        f'        category: [.{c["category"]}], city: "{c["city"]}",',
        f'        rating: {c["rating"]}, reviewCount: {c["reviewCount"]},',
        f'        responseTime: .{c["responseTime"]}, yearsActive: {c["yearsActive"]},',
        f'        photos: [{photos_swift}],',
        f'        priceTiers: [{tiers_swift}],',
        f'        phone: {swift_optional_string(c["phone"])},',
        f'        licenseNumber: nil, isVerified: {str(c["isVerified"]).lower()}',
        "    ),",
    ]

lines += ["]", ""]

out_path = "/Users/test/Desktop/FIXR/FIXR/Models/MockData.swift"
with open(out_path, "w") as f:
    f.write("\n".join(lines))

print(f"📄 Written → {out_path}")
print(f"   {len(contractors)} contractors, categories: {[c[0] for c in CATEGORIES]}")
