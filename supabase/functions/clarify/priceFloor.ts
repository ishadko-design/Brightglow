/** Home jobs below project size still need their price drivers settled before
 *  the chat finishes: "Patch flat roof" finished with no real question and
 *  priced as a $6.4k-17k replacement (2026-10-02). Size-driven trades price by
 *  area, material and scope, so they need two answers; any other home job one.
 *  Projects keep their own, higher floor (MIN_PROJECT_QUESTIONS in index.ts). */
const SIZE_DRIVEN_CATEGORIES = new Set([
  "Roofing", "Flooring", "Painting", "Carpentry", "Windows & Doors", "Landscaping",
]);

export function minHomeQuestions(category: string | undefined): number {
  return category && SIZE_DRIVEN_CATEGORIES.has(category) ? 2 : 1;
}

/** Auto/moto: a body-panel job swings from PDR to respray on damage size and
 *  paint state, so it needs a cost question beyond the vehicle; glass and
 *  routine service price fine from the service itself. */
export function minQuestions(vertical: string | undefined, category: string | undefined): number {
  if (vertical === "auto_moto") return category === "Body & Paint" ? 2 : 0;
  return minHomeQuestions(category);
}
