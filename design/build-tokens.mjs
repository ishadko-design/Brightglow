// Generates Brightglow/Theme/DesignTokens.generated.swift from design/tokens.json.
// Zero dependencies. Run with:  npm run tokens   (or: node design/build-tokens.mjs)
// The tokens file is the single source of truth, shared with Figma via Tokens Studio.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tokens = JSON.parse(readFileSync(join(root, "design/tokens.json"), "utf8")).global;
const OUT = join(root, "Brightglow/Theme/DesignTokens.generated.swift");

const upper = (s) => s.charAt(0).toUpperCase() + s.slice(1);

// Map a token font family + weight to its iOS PostScript font name.
const fontFace = (family, weight) => {
  const w = { "800": "ExtraBold", "700": "Bold", "600": "SemiBold",
              "500": "Medium", "400": "Regular", "300": "Light" }[String(weight)] || "Regular";
  return `${family}-${w}`;
};

// Render a token color value (#hex or rgba(...)) as a SwiftUI Color literal.
const swiftColor = (value) => {
  const m = value.match(/rgba?\(([^)]+)\)/i);
  if (m) {
    const [r, g, b, a = "1"] = m[1].split(",").map((s) => s.trim());
    const f = (n) => (Number(n) / 255).toFixed(4);
    return `Color(.sRGB, red: ${f(r)}, green: ${f(g)}, blue: ${f(b)}, opacity: ${Number(a)})`;
  }
  return `Color(hex: "${value}")`;
};

const lines = [];
lines.push("// AUTO-GENERATED from design/tokens.json — do not edit by hand.");
lines.push("// Regenerate with:  npm run tokens");
lines.push("import SwiftUI", "");
lines.push("enum DesignTokens {", "");

lines.push("    // MARK: - Colors");
for (const [name, t] of Object.entries(tokens.color ?? {}))
  lines.push(`    static let color${upper(name)} = ${swiftColor(t.value)}`);

lines.push("", "    // MARK: - Spacing");
for (const [name, t] of Object.entries(tokens.space ?? {}))
  lines.push(`    static let space${name}: CGFloat = ${Number(t.value)}`);

lines.push("", "    // MARK: - Radius");
for (const [name, t] of Object.entries(tokens.radius ?? {}))
  lines.push(`    static let radius${upper(name)}: CGFloat = ${Number(t.value)}`);

lines.push("", "    // MARK: - Size");
for (const [name, t] of Object.entries(tokens.size ?? {}))
  lines.push(`    static let size${upper(name)}: CGFloat = ${Number(t.value)}`);

lines.push("", "    // MARK: - Typography");
for (const [name, t] of Object.entries(tokens.typography ?? {})) {
  const v = t.value;
  lines.push(`    static let typography${upper(name)} = Font.custom("${fontFace(v.fontFamily, v.fontWeight)}", size: ${Number(v.fontSize)})`);
}

lines.push("}", "");
writeFileSync(OUT, lines.join("\n"));
console.log(`✓ wrote ${OUT}`);
