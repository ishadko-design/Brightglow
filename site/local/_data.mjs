// Data for the programmatic local landing pages (site/local/*.html).
// Regenerate the pages after editing this file:  node site/local/_build.mjs
//
// Price bands are REAL, held-out figures lifted from
// supabase/functions/pricing/groundTruth.ts (Homewyse, This Old House, Forbes
// Home, Bob Vila, Thumbtack, etc., 2026). National bands; each city page scales
// the labour-heavy portion by a documented local cost index and says so, so no
// page invents a number that isn't traceable.

// Bay-Area cities we generate a page for, with a rough local labour cost index
// (1.00 = U.S. average). These are ballpark cost-of-living/labour multipliers
// for the metro — stated on each page as an approximation, never as a quote.
export const CITIES = [
  { slug: "san-francisco", name: "San Francisco", index: 1.35 },
  { slug: "daly-city",     name: "Daly City",     index: 1.25 },
  { slug: "san-mateo",     name: "San Mateo",     index: 1.28 },
  { slug: "oakland",       name: "Oakland",       index: 1.20 },
  { slug: "berkeley",      name: "Berkeley",      index: 1.22 },
  { slug: "san-jose",      name: "San Jose",      index: 1.25 },
  { slug: "fremont",       name: "Fremont",       index: 1.20 },
  { slug: "hayward",       name: "Hayward",       index: 1.15 },
];

// Each trade: the search term it targets, and a handful of real jobs with
// national bands + the "what drives the price" and FAQ content that makes the
// page genuinely useful (not a thin doorway page). `wide: true` marks a band
// that spans widely (we soften the local scaling note for those).
export const TRADES = [
  {
    slug: "plumbing",
    name: "Plumbing",
    verb: "plumber",
    intro: "From a dripping faucet to a new water heater, here's what plumbing work typically costs in {CITY} — and how to see real pro photos and get an instant estimate before you call anyone.",
    jobs: [
      { label: "Fix a running toilet",        low: 159,  high: 311 },
      { label: "Repair a dripping faucet",    low: 269,  high: 324 },
      { label: "Diagnose a hidden leak",      low: 350,  high: 2000, wide: true },
      { label: "Replace a water heater (tank)",low: 1200, high: 2300 },
      { label: "Install a tankless water heater", low: 2100, high: 4000 },
    ],
    drivers: [
      "How accessible the fixture or pipe is — a slab or behind-wall leak costs far more than an exposed one.",
      "Whether parts (the fixture, the heater itself) are included or you supply them.",
      "Permit and inspection requirements for water-heater and gas work in California.",
      "Emergency or after-hours call-outs, which carry a premium.",
    ],
    faqs: [
      ["How much does a plumber cost in {CITY}?", "Most common plumbing repairs in {CITY} run between {MIN} and {MAX} depending on the job. Small fixes like a running toilet are at the low end; water-heater and re-pipe work at the high end."],
      ["Do I need a licensed plumber in California?", "For most installation and gas work, yes — California requires a C-36 licensed plumbing contractor. Brightglow shows license status so you can confirm before hiring."],
      ["Can I get a price before calling around?", "Yes. Snap a photo or describe the job in the Brightglow app and you'll get an instant price range plus photos of local pros' actual work."],
    ],
  },
  {
    slug: "electrical",
    name: "Electrical",
    verb: "electrician",
    intro: "Panel upgrades, tripping breakers, solar — here's what electrical work typically costs in {CITY}, with real pro photos and an instant estimate before you hire.",
    jobs: [
      { label: "Fix a breaker that keeps tripping", low: 100,  high: 400 },
      { label: "Upgrade electrical panel to 200A",  low: 1300, high: 3000 },
      { label: "Install solar panels",              low: 15000, high: 28000, wide: true },
    ],
    drivers: [
      "The size of the service upgrade and whether the utility drop needs work.",
      "How much new wiring has to be run inside finished walls.",
      "Permit and inspection fees, which are required for panel and solar work.",
      "For solar: system size and roof complexity (this band is before the federal credit).",
    ],
    faqs: [
      ["How much does an electrician cost in {CITY}?", "Small electrical repairs in {CITY} typically start around {MIN}; larger jobs like a 200-amp panel upgrade run into the low thousands."],
      ["Do electricians in California need a license?", "Yes — a C-10 electrical contractor license. Brightglow surfaces license status so you can verify before you hire."],
      ["Is the solar price before or after tax credits?", "The range shown is the gross cost before the federal tax credit. Your net cost is typically lower."],
    ],
  },
  {
    slug: "hvac",
    name: "Heating & Air (HVAC)",
    verb: "HVAC contractor",
    intro: "AC that won't cool, an aging furnace, or a full central-air install — here's what HVAC work typically costs in {CITY}, with pro photos and an instant estimate.",
    jobs: [
      { label: "Diagnose AC that won't cool",       low: 100,  high: 610 },
      { label: "Install central air conditioning",  low: 3900, high: 7900 },
      { label: "Replace a gas furnace",             low: 1700, high: 10000, wide: true },
    ],
    drivers: [
      "Whether existing ductwork can be reused or has to be replaced.",
      "The unit's size (tonnage) and efficiency rating.",
      "Fuel type and any gas-line or electrical changes needed.",
      "Permit and inspection requirements for mechanical work.",
    ],
    faqs: [
      ["How much does HVAC work cost in {CITY}?", "A service diagnosis in {CITY} often runs a few hundred dollars; a full central-air install lands in the several-thousand range depending on size and ductwork."],
      ["Do I need a licensed HVAC contractor?", "Yes — California requires a C-20 HVAC license for installs. Brightglow shows license status up front."],
      ["Repair or replace?", "If the system is over ~12–15 years old and the repair is a big-ticket component, replacement is often the better value. Get both quotes in-app."],
    ],
  },
  {
    slug: "painting",
    name: "Painting",
    verb: "painter",
    intro: "Repainting a room or the whole interior — here's what painting typically costs in {CITY}, with photos of local painters' real work and an instant estimate.",
    jobs: [
      { label: "Repaint a 250 sq ft room", low: 250, high: 875 },
    ],
    perSqft: { low: 1, high: 3.5, unit: "sq ft (repaint)" },
    drivers: [
      "Square footage and ceiling height — the biggest driver by far.",
      "How much prep is needed: patching, sanding, priming bare or stained walls.",
      "Number of colors, accent walls, and trim/door detail.",
      "Paint grade — premium paint costs more but lasts longer.",
    ],
    faqs: [
      ["How much does it cost to paint a room in {CITY}?", "A standard room in {CITY} typically runs {MIN} to {MAX}, or roughly {SQFTMIN}–{SQFTMAX} per square foot for a repaint including labor."],
      ["Does that include paint?", "Usually labor plus standard paint. Premium paint or heavy prep raises the price. Your in-app estimate breaks it down."],
      ["How do I compare painters?", "Brightglow shows real photos of each painter's finished work — so you're judging craftsmanship, not just price."],
    ],
  },
  {
    slug: "flooring",
    name: "Flooring",
    verb: "flooring installer",
    intro: "New hardwood, laminate, or tile — here's what flooring installation typically costs in {CITY}, with photos of local installers' work and an instant estimate.",
    jobs: [
      { label: "Install hardwood floors (200 sq ft)", low: 1200, high: 2400 },
    ],
    perSqft: { low: 6, high: 12, unit: "sq ft (hardwood, installed)" },
    drivers: [
      "Material choice — laminate and vinyl are cheaper than solid hardwood or tile.",
      "Square footage and room layout (lots of cuts and corners add labor).",
      "Whether old flooring has to be torn out and hauled away.",
      "Subfloor prep or leveling if the existing floor is uneven.",
    ],
    faqs: [
      ["How much does flooring cost in {CITY}?", "Hardwood installation in {CITY} typically runs about {SQFTMIN}–{SQFTMAX} per square foot installed — roughly {MIN} to {MAX} for a 200 sq ft room."],
      ["Which flooring is cheapest?", "Laminate and luxury vinyl plank are the budget options; solid hardwood and natural stone tile sit at the top. Get a range for each in-app."],
      ["Is old-floor removal included?", "Sometimes. Tear-out and disposal can be a separate line item — your estimate flags it."],
    ],
  },
  {
    slug: "roofing",
    name: "Roofing",
    verb: "roofer",
    intro: "A leaking roof or a full re-roof — here's what roofing typically costs in {CITY}, with photos of local roofers' work and an instant estimate before you commit.",
    jobs: [
      { label: "Replace asphalt shingle roof (1,700 sq ft)", low: 6000, high: 9000 },
    ],
    drivers: [
      "Roof size (measured in squares) and pitch — steep roofs cost more to work on.",
      "Whether the old roof is torn off or new layers go over it.",
      "Material: asphalt shingle is cheapest; metal, tile, and slate cost much more.",
      "Decking repairs found once the old roof is removed.",
    ],
    faqs: [
      ["How much does a new roof cost in {CITY}?", "A full asphalt-shingle replacement in {CITY} on an average home typically runs {MIN} to {MAX}, tear-off included."],
      ["Do I need a permit to re-roof in California?", "Yes, re-roofing requires a permit. A licensed C-39 roofing contractor pulls it. Brightglow shows license status."],
      ["Repair or replace?", "A localized leak may just need a repair. If the roof is near end-of-life, replacement is usually the better long-term value — compare both in-app."],
    ],
  },
];
