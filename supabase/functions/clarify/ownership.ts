// Deterministic guards for the clarify chat (kept out of index.ts so tests can
// import them without starting the server).

/** The request's verb already says the user HAS the equipment ("install my
 *  sauna", "hook up the hot tub") — so asking whether they have/bought it is
 *  redundant. The prompt says so; the model asked anyway in 4 of 4 runs
 *  (2026-09-30), hence this deterministic guard. */
export function impliesOwned(request: string): boolean {
  return /\b(install|installing|installation|hook(ing)?\s*up|connect|wire|wiring|set\s*up|mount)\b/i
    .test(request) && !/\b(buy|purchase|supply|provide|sell)\b/i.test(request);
}
export function asksOwnership(question: string): boolean {
  return /\b(already (have|own|got|purchased|bought)|on order|still need (to )?(buy|get|order)|need(s)? (to be|one) built|purchased|bought it|do you (have|own) (the|a|your))\b/i
    .test(question);
}

/** A PROJECT's details must carry the "project: …; includes: …" scope — it is
 *  how pricing knows to price the whole job. When the model leaves details
 *  empty (seen 2026-09-30: the sauna install then priced as a bare circuit,
 *  $800–3k), rebuild it from job_spec. */
export function projectDetails(
  details: string, title: string, spec: { complexity?: string; components?: string[] } | undefined,
  owned: boolean,
): string {
  if (spec?.complexity !== "project" || /\bproject:/i.test(details)) return details;
  const comps = (spec.components ?? []).filter(Boolean);
  if (!title || comps.length === 0) return details;
  const unit = owned ? " (unit already purchased, not included)" : "";
  const rebuilt = `project: ${title}${unit}; includes: ${comps.join(", ")}`;
  return details ? `${rebuilt}; ${details}` : rebuilt;
}

