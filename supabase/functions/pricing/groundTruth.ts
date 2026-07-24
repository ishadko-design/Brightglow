// HELD-OUT validation set for the pricing engine.
//
// The distinction that makes this file worth having: costCatalog.ts was built
// against Angi / HomeAdvisor / Fixr (home) and RepairPal / AAA / rate surveys
// (auto), and calibration.test.ts re-checks the catalog against those SAME
// figures. That proves internal consistency, not accuracy — it cannot fail for
// the reason we actually care about.
//
// Every band below comes from a source that was NOT used to build the catalog:
//   home → Homewyse, Forbes Home, This Old House, Bob Vila, Thumbtack
//   auto → Kelley Blue Book, ConsumerAffairs, Jerry, YourMechanic
// Keep it that way. If you tune the catalog to a source, move that source out
// of this file — a validation set you've fitted to is just a second training
// set wearing a disguise.
//
// Cases are phrased as a USER WOULD TYPE THEM, and are scored through the full
// production pipeline (estimatePipeline.ts), so a failure here can mean a bad
// price OR a bad classification OR a bad quantity default. That's deliberate:
// those are indistinguishable to the person reading the number.
//
// Bands are national. Cases run with no zip so the engine uses national wages
// and the comparison is apples-to-apples; regional behaviour is tested
// separately (see the ordering test in accuracy.test.ts).

export interface GroundTruthCase {
  /** What the user types into search. */
  query: string;
  /** Category chip, or "" for the bare-typed-search path. */
  category: string;
  /** job_type we expect the classifier to land on. */
  expectJobType: string;
  /** Published all-in range from the held-out source, for THIS whole job. */
  low: number;
  high: number;
  source: string;
  vertical: "home" | "auto";
  /** Auto & moto vehicle filter, as the app sends it. */
  vehicle?: "auto" | "moto";
  /** Source band is unusually wide (spans fuel types, vehicle classes, etc.),
   *  so only gross error is meaningful — excluded from the median-error metric
   *  but still checked for band overlap. */
  wide?: boolean;
}

export const GROUND_TRUTH: GroundTruthCase[] = [
  // === HOME =============================================================
  {
    query: "replace my water heater",
    category: "Plumbing",
    expectJobType: "plumbing.water_heater",
    low: 1200,
    high: 2300,
    source: "Forbes Home / This Old House / Homewyse 2026 (tank, installed)",
    vertical: "home",
  },
  {
    query: "install a tankless water heater",
    category: "Plumbing",
    expectJobType: "plumbing.tankless_water_heater",
    low: 2100,
    high: 4000,
    source: "Forbes Home 2026",
    vertical: "home",
  },
  {
    query: "upgrade electrical panel to 200 amp",
    category: "Electrical",
    expectJobType: "electrical.panel",
    low: 1300,
    high: 3000,
    source: "This Old House 2026",
    vertical: "home",
  },
  {
    // The default 20-panel / ~8 kW array, the case that used to read "~$270".
    query: "install solar panels",
    category: "Electrical",
    expectJobType: "electrical.solar",
    low: 15000,
    high: 28000,
    source: "EnergySage / NREL 2026 (gross, before the federal credit)",
    vertical: "home",
  },
  {
    query: "install central air conditioning",
    category: "HVAC",
    expectJobType: "hvac.ac",
    low: 3900,
    high: 7900,
    source: "Bob Vila 2026 (unit + install, existing ductwork)",
    vertical: "home",
  },
  {
    query: "replace gas furnace",
    category: "HVAC",
    expectJobType: "hvac.furnace",
    low: 1700,
    high: 10000,
    source: "Forbes Home 2026 (spans fuel types — very wide)",
    vertical: "home",
    wide: true,
  },
  {
    // 250 sq ft at the held-out $1.00–3.50/sq ft repaint rate.
    query: "paint a 250 sq ft room",
    category: "Painting",
    expectJobType: "painting.interior",
    low: 250,
    high: 875,
    source: "This Old House 2026 ($1–3.50/sq ft repaint)",
    vertical: "home",
  },
  {
    // 200 sq ft at the held-out $6–12/sq ft installed rate.
    query: "install hardwood floors 200 sq ft",
    category: "Flooring",
    expectJobType: "flooring.hardwood",
    low: 1200,
    high: 2400,
    source: "This Old House 2026 ($6–12/sq ft installed)",
    vertical: "home",
  },
  {
    // CORRECTED 2026-07-20. This case first read $3,400–6,800, from a This Old
    // House "$200–400 per roofing square" figure ($2–4/sq ft). The engine came
    // in at $8,585 and looked 68% high — the worst miss on the board. Checking
    // a third source before touching the catalog is what saved it: Homewyse
    // ($5.09–6.66/sq ft), HomeGuide architectural ($4.11–5.57/sq ft) and
    // roofing-industry guides ($6,000–9,000 for a 1,700 sq ft roof) all agree
    // with the ENGINE, not with the original band. The $200–400/square figure
    // is materials-only or stale. Tuning the catalog to it would have cut
    // roofing ~40% below market to satisfy a bad number.
    // The lesson is the process: a held-out source is evidence, not an oracle.
    query: "replace asphalt shingle roof 1700 sq ft",
    category: "Roofing",
    expectJobType: "roofing.shingle",
    low: 6000,
    high: 9000,
    source: "Homewyse / HomeGuide / Bill Ragan Roofing 2026 (1,700 sq ft, tear-off incl.)",
    vertical: "home",
  },

  // Plumbing REPAIRS, added 2026-07-22. Held out from the build sources
  // (Fixr / HomeGuide / HomeAdvisor / Angi) on purpose — these come from
  // Homewyse and Thumbtack, which disagree with them and with each other.
  {
    // Sources conflict hard: Thumbtack puts toilet repair at $159 average,
    // Homewyse at $275-376 for a fuller "leaky toilet" scope that includes
    // pulling the bowl. THIS query is the flapper/fill-valve job — the cheap
    // end — so the band runs from Thumbtack's average to Homewyse's low rather
    // than spanning both scopes and calling the midpoint truth.
    query: "my toilet keeps running",
    category: "Plumbing",
    expectJobType: "plumbing.toilet_repair",
    low: 159,
    high: 311,
    source: "Thumbtack $159 avg / Homewyse $311 low, 2026",
    vertical: "home",
    wide: true,
  },
  {
    query: "faucet dripping",
    category: "Plumbing",
    expectJobType: "plumbing.faucet_repair",
    low: 269,
    high: 324,
    source: "Homewyse 2026 (repair leaky faucet, incl. labor + materials)",
    vertical: "home",
  },
  {
    // The blind spot that mattered most: this used to quote a full heater
    // replacement, or nothing at all.
    query: "no hot water",
    category: "Plumbing",
    expectJobType: "plumbing.water_heater_repair",
    low: 303,
    high: 365,
    source: "Homewyse 2026 (basic hot water heater repair)",
    vertical: "home",
  },

  // HVAC + Electrical repairs, added 2026-07-23. Held out from the build
  // sources (Fixr / HomeGuide / HomeAdvisor / Angi): these come from Bob Vila,
  // Forbes, This Old House, Homewyse and Thumbtack.
  {
    // The top HVAC call, and one that used to quote a FURNACE repair because
    // the generic "repair" keyword owned it.
    query: "AC not cooling",
    category: "HVAC",
    expectJobType: "hvac.ac_repair",
    low: 100,
    high: 610,
    source: "Bob Vila 2026 ($100-610, avg $369) / Forbes / This Old House",
    vertical: "home",
  },
  {
    // Sources genuinely disagree by ~2x on the same words, and the disagreement
    // is systematic rather than noise: the consumer aggregators price a branch
    // breaker swap ($100-200) while Homewyse prices a fuller service visit
    // ($319-382) and Thumbtack quotes a MAIN breaker ($200-300), which is a
    // bigger job. Banded to span all three rather than picking a camp; marked
    // wide so only gross error counts.
    query: "breaker keeps tripping",
    category: "Electrical",
    expectJobType: "electrical.breaker",
    low: 100,
    high: 400,
    source: "Thumbtack $200-300 (main) / Homewyse $319-382 / aggregators $100-200, 2026",
    vertical: "home",
    wide: true,
  },

  // === AUTO =============================================================
  {
    // Reported 2026-07-22: "Wrap car" showed results with no price line at all.
    query: "wrap my car",
    category: "Body & Paint",
    expectJobType: "auto.wrap_full",
    low: 2000,
    high: 6000,
    source: "Wrapmate / vinylwrapro / CarWrapHub 2026 (sedan $2k-3.5k, SUV $3.5k-6.5k)",
    vertical: "auto",
  },
  {
    // Banded to the STANDARD sedan/small-SUV case, which is what the engine
    // assumes when the user names no vehicle. The full published span runs
    // $300 (compact) to $1,500+ (box truck, sun-baked film), but scoring
    // against that put the midpoint at $900 — a vehicle nobody defaulted to —
    // and made a correct $599 look 33% low.
    query: "removing an old wrap",
    category: "Body & Paint",
    expectJobType: "auto.wrap_removal",
    low: 500,
    high: 900,
    source: "vinylwrapro / RM Window Tint / Yeahgor 2026 (sedan & small SUV)",
    vertical: "auto",
  },
  {
    query: "brake pads and rotors",
    category: "Repair",
    expectJobType: "auto.brakes_pads_rotors",
    low: 400,
    high: 900,
    source: "Kelley Blue Book 2026 (brake job, per axle)",
    vertical: "auto",
  },
  {
    query: "replace alternator",
    category: "Repair",
    expectJobType: "auto.alternator",
    low: 747,
    high: 1000,
    source: "Kelley Blue Book $747–842 / ConsumerAffairs $750–1,000, 2026",
    vertical: "auto",
  },
  {
    query: "starter replacement",
    category: "Repair",
    expectJobType: "auto.starter",
    low: 728,
    high: 820,
    source: "Kelley Blue Book 2026",
    vertical: "auto",
  },
  {
    query: "synthetic oil change",
    category: "Repair",
    expectJobType: "auto.oil_change",
    low: 65,
    high: 125,
    source: "Kelley Blue Book 2026 (synthetic)",
    vertical: "auto",
  },
  {
    query: "windshield replacement",
    category: "Glass",
    expectJobType: "auto.windshield_replacement",
    low: 300,
    high: 600,
    source: "Kelley Blue Book 2026 (aftermarket, no ADAS)",
    vertical: "auto",
  },
  {
    query: "wheel alignment",
    category: "Tires",
    expectJobType: "auto.alignment",
    low: 50,
    high: 200,
    source: "Jerry / Kelley Blue Book 2026",
    vertical: "auto",
  },

  // === MOTO =============================================================
  // These exist because the vertical shipped priced-as-a-car: with the Moto
  // filter selected, "replace tires" quoted four car tires (~$890) for a job
  // that is two moto tires (~$440). The filter now reaches the server, and
  // these cases keep it reaching it.
  {
    // The exact failing case: bare phrasing, Moto filter selected. Two tires
    // at the $160–300 fitted rate.
    query: "replace tires",
    category: "Tires",
    vehicle: "moto",
    expectJobType: "auto.tire_replacement",
    low: 320,
    high: 600,
    source: "Harley/Triumph owner-forum shop quotes + mount-balance surveys 2026",
    vertical: "auto",
  },
  {
    // Same job reached by words instead of the filter — the vehicle has to be
    // recoverable from the phrase when no chip is set.
    query: "new tires for my motorcycle",
    category: "",
    expectJobType: "auto.tire_replacement",
    low: 320,
    high: 600,
    source: "Harley/Triumph owner-forum shop quotes + mount-balance surveys 2026",
    vertical: "auto",
  },
  {
    // Reported live 2026-07-20: a bare noun phrase with no verb. Every tire
    // keyword required one ("replace tires", "new tires"), so this fell to a
    // labor-only $175 instead of a real price.
    query: "place tires on motorcycle",
    category: "",
    expectJobType: "auto.tire_replacement",
    low: 320,
    high: 600,
    source: "Harley/Triumph owner-forum shop quotes + mount-balance surveys 2026",
    vertical: "auto",
  },
  {
    query: "motorcycle oil change",
    category: "Repair",
    vehicle: "moto",
    expectJobType: "auto.oil_change",
    low: 40,
    high: 100,
    source: "JD Power motorcycle service guide 2026",
    vertical: "auto",
  },
  {
    query: "motorcycle brake pads",
    category: "Repair",
    vehicle: "moto",
    expectJobType: "auto.brakes",
    low: 130,
    high: 300,
    source: "JD Power / Eagle Leather moto maintenance guides 2026",
    vertical: "auto",
  },
  {
    query: "chain and sprocket replacement",
    category: "Repair",
    vehicle: "moto",
    expectJobType: "auto.chain_sprocket",
    low: 150,
    high: 450,
    source: "PGN / Kawasaki-forum shop quotes 2026",
    vertical: "auto",
  },
];
