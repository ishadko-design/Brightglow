import { detectVehicle } from "./pricingEngine.ts";
import { estimateInHouse } from "./estimatePipeline.ts";
// Vehicle detection is a hardcoded word list — the same brittleness, one axis over.
const qs = ["my Ducati needs new tires","new tires for my Harley","tires for my bike",
            "new tires for my Yamaha R6","two-wheeler tire change","new tires for my motorcycle"];
for (const q of qs) {
  const r = estimateInHouse({category:"Tires", description:q});
  const t = r.kind==="range" ? `$${Math.round(r.typical)} qty=${r.quantity}` : r.kind;
  console.log(q.padEnd(30), "vehicle:", String(detectVehicle(q)).padEnd(5), t);
}
