// USPS 3-digit ZIP prefix → state, for routing a request zip to its OEWS
// wage rows (STATE_WAGES in wageTable.generated.ts). Prefix allocation is
// set by USPS and effectively frozen — this table is maintained by hand.
// Prefixes that don't map to a wage area (military APO/FPO, PR/VI/GU —
// no OEWS state rows survive ingest for the territories) return null and
// the engine prices with NATIONAL_WAGES.

const ZIP3_RANGES: Array<[number, number, string | null]> = [
  [5, 5, "NY"],      // 005 Holtsville
  [6, 9, null],      // PR / VI — no state wage rows
  [10, 27, "MA"],
  [28, 29, "RI"],
  [30, 38, "NH"],
  [39, 49, "ME"],
  [50, 59, "VT"],
  [60, 69, "CT"],
  [70, 89, "NJ"],
  [90, 98, null],    // APO/FPO Europe
  [100, 149, "NY"],
  [150, 196, "PA"],
  [197, 199, "DE"],
  [200, 200, "DC"],
  [201, 201, "VA"],
  [202, 205, "DC"],
  [206, 219, "MD"],
  [220, 246, "VA"],
  [247, 268, "WV"],
  [270, 289, "NC"],
  [290, 299, "SC"],
  [300, 319, "GA"],
  [320, 339, "FL"],
  [340, 340, null],  // APO/FPO Americas
  [341, 349, "FL"],
  [350, 369, "AL"],
  [370, 385, "TN"],
  [386, 397, "MS"],
  [398, 399, "GA"],
  [400, 427, "KY"],
  [430, 459, "OH"],
  [460, 479, "IN"],
  [480, 499, "MI"],
  [500, 528, "IA"],
  [530, 549, "WI"],
  [550, 567, "MN"],
  [570, 577, "SD"],
  [580, 588, "ND"],
  [590, 599, "MT"],
  [600, 629, "IL"],
  [630, 658, "MO"],
  [660, 679, "KS"],
  [680, 693, "NE"],
  [700, 714, "LA"],
  [716, 729, "AR"],
  [730, 749, "OK"],
  [750, 799, "TX"],
  [800, 816, "CO"],
  [820, 831, "WY"],
  [832, 838, "ID"],
  [840, 847, "UT"],
  [850, 865, "AZ"],
  [870, 884, "NM"],
  [885, 885, "TX"],  // El Paso carve-out
  [889, 898, "NV"],
  [900, 961, "CA"],
  [962, 966, null],  // APO/FPO Pacific
  [967, 968, "HI"],
  [969, 969, null],  // Guam
  [970, 979, "OR"],
  [980, 994, "WA"],
  [995, 999, "AK"],
];

/** Two-letter state for a 5-digit (or 3-digit-prefix) zip, or null when the
 *  prefix is unallocated, military, or a territory without OEWS state rows. */
export function stateForZip(zip: string | undefined): string | null {
  if (!zip) return null;
  const m = zip.trim().match(/^(\d{3})/);
  if (!m) return null;
  const prefix = Number(m[1]);
  for (const [lo, hi, state] of ZIP3_RANGES) {
    if (prefix >= lo && prefix <= hi) return state;
  }
  return null;
}
